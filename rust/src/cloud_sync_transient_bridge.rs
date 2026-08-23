//! Default-off D1 Cloud Sync semantic conversion boundary.
//!
//! The D0 journal supplies only protected capabilities and content-free
//! digests. This module validates the complete active account/scope/generation
//! and native-store fence, unprotects one raw record inside Rust, decrypts it,
//! and invokes the canonical converter. Raw Apple identifiers, PCS material,
//! and CloudKit records never cross Flutter Rust Bridge.

#![allow(dead_code)]

use std::{
    io::Read,
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    sync::Arc,
};

use flate2::read::GzDecoder;
use prost::Message as _;
use rustpush::{
    cloud_messages::{
        CloudAttachment, CloudChat, CloudMessage, CloudMessagesClient, MESSAGES_SERVICE,
    },
    cloudkit::pcs_keys_for_record,
    cloudkit_proto::{
        record::Field, retrieve_changes_response::RecordChange, CloudKitEncryptor, CloudKitRecord,
        Record,
    },
    pcs::PCSEncryptor,
    DefaultAnisetteProvider, PushError,
};
use sha2::{Digest, Sha256};

use crate::{
    cloud_sync_canonical_converter::{
        convert_attachment, convert_chat, convert_message, convert_tombstone,
        CloudCanonicalConversionContext, CloudCanonicalConversionOutcome,
        CloudCanonicalQuarantineReason, CloudRawRecordPresence,
    },
    cloud_sync_canonical_dto::{
        CloudCanonicalAliasKind, CloudCanonicalEntityKind, CloudCanonicalHash,
        CloudCanonicalMessageAssociation, CloudCanonicalMutation, CloudCanonicalPayload,
        CloudCanonicalValidationFailure,
    },
    cloud_sync_native_fetch::{
        cloud_sync_unprotect_raw_envelope, CloudNativeFailureCategory, CloudNativeProtectionScope,
        CloudNativeRawEnvelope, CloudNativeRawEnvelopeKind, CloudNativeSafeCode, CloudNativeStream,
    },
    cloud_sync_protector,
    cloud_sync_semantic_identity::CloudSemanticIdentifierHasher,
};

const MAX_DECOMPRESSED_FIELD_BYTES: usize = 16 * 1024 * 1024;
const MAX_DECOMPRESSED_RECORD_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudTransientExpectedChangeKind {
    Save,
    Delete,
    Quarantined,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CloudTransientBridgeFailure {
    InvalidRequest,
    ActiveAccountMismatch,
    ScopeMismatch,
    GenerationMismatch,
    StoreIdentityMismatch,
    ProtectedReferenceMismatch,
    MalformedRecord,
    OversizedRecord,
    PcsUnavailable,
    RetryableUpstream,
    DecoderFailure,
}

pub(crate) enum CloudTransientDecodeOutcome {
    Ready(Box<CloudCanonicalMutation>),
    Deferred(crate::cloud_sync_canonical_converter::CloudCanonicalDeferredReason),
    Quarantined(CloudCanonicalQuarantineReason),
    Failure(CloudTransientBridgeFailure),
}

impl std::fmt::Debug for CloudTransientDecodeOutcome {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Ready(_) => formatter.write_str("CloudTransientDecodeOutcome::Ready(redacted)"),
            Self::Deferred(reason) => formatter
                .debug_tuple("CloudTransientDecodeOutcome::Deferred")
                .field(reason)
                .finish(),
            Self::Quarantined(reason) => formatter
                .debug_tuple("CloudTransientDecodeOutcome::Quarantined")
                .field(reason)
                .finish(),
            Self::Failure(failure) => formatter
                .debug_tuple("CloudTransientDecodeOutcome::Failure")
                .field(failure)
                .finish(),
        }
    }
}

#[derive(Clone)]
pub(crate) struct CloudTransientTombstoneMapping {
    entity_kind: CloudCanonicalEntityKind,
    logical_entity_key_hash: CloudCanonicalHash,
}

impl CloudTransientTombstoneMapping {
    pub(crate) fn new(
        entity_kind: CloudCanonicalEntityKind,
        logical_entity_key_hash: String,
    ) -> Result<Self, CloudTransientBridgeFailure> {
        let logical_entity_key_hash = CloudCanonicalHash::new(logical_entity_key_hash)
            .map_err(|_| CloudTransientBridgeFailure::InvalidRequest)?;
        Ok(Self {
            entity_kind,
            logical_entity_key_hash,
        })
    }
}

pub(crate) struct CloudTransientDecodeRequest {
    storage_directory: PathBuf,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    container: String,
    database: String,
    zone: String,
    stream_kind: String,
    schema_version: u32,
    stream: CloudNativeStream,
    generation: u64,
    expected_change_kind: CloudTransientExpectedChangeKind,
    expected_change_id: CloudCanonicalHash,
    expected_record_id_hash: CloudCanonicalHash,
    expected_etag_hash: Option<CloudCanonicalHash>,
    expected_payload_sha256: String,
    expected_payload_length: Option<u64>,
    expected_server_modified_at_millis: Option<i64>,
    protected_raw_envelope_reference: String,
    tombstone_mapping: Option<CloudTransientTombstoneMapping>,
}

impl CloudTransientDecodeRequest {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        storage_directory: PathBuf,
        expected_account_fingerprint: String,
        expected_protected_store_identity: String,
        container: String,
        database: String,
        zone: String,
        stream_kind: String,
        schema_version: u32,
        stream: CloudNativeStream,
        generation: u64,
        expected_change_kind: CloudTransientExpectedChangeKind,
        expected_change_id: String,
        expected_record_id_hash: String,
        expected_etag_hash: Option<String>,
        expected_payload_sha256: String,
        expected_payload_length: Option<u64>,
        expected_server_modified_at_millis: Option<i64>,
        protected_raw_envelope_reference: String,
        tombstone_mapping: Option<CloudTransientTombstoneMapping>,
    ) -> Result<Self, CloudTransientBridgeFailure> {
        if !storage_directory.is_dir()
            || !is_digest(&expected_account_fingerprint)
            || !is_store_identity(&expected_protected_store_identity)
            || container != "com.apple.messages.cloud"
            || database != "private"
            || zone != stream.zone()
            || stream_kind != "messages"
            || schema_version != 2
            || generation == 0
            || !is_sha256_hex(&expected_payload_sha256)
            || !is_protected_reference(&protected_raw_envelope_reference)
            || !semantic_stream_is_supported(stream)
        {
            return Err(CloudTransientBridgeFailure::InvalidRequest);
        }
        let expected_change_id = CloudCanonicalHash::new(expected_change_id)
            .map_err(|_| CloudTransientBridgeFailure::InvalidRequest)?;
        let expected_record_id_hash = CloudCanonicalHash::new(expected_record_id_hash)
            .map_err(|_| CloudTransientBridgeFailure::InvalidRequest)?;
        let expected_etag_hash = expected_etag_hash
            .map(CloudCanonicalHash::new)
            .transpose()
            .map_err(|_| CloudTransientBridgeFailure::InvalidRequest)?;
        let is_delete = expected_change_kind == CloudTransientExpectedChangeKind::Delete;
        if is_delete != tombstone_mapping.is_some() {
            return Err(CloudTransientBridgeFailure::InvalidRequest);
        }
        if tombstone_mapping
            .as_ref()
            .is_some_and(|mapping| !entity_kind_matches_stream(mapping.entity_kind, stream))
        {
            return Err(CloudTransientBridgeFailure::InvalidRequest);
        }
        Ok(Self {
            storage_directory,
            expected_account_fingerprint,
            expected_protected_store_identity,
            container,
            database,
            zone,
            stream_kind,
            schema_version,
            stream,
            generation,
            expected_change_kind,
            expected_change_id,
            expected_record_id_hash,
            expected_etag_hash,
            expected_payload_sha256,
            expected_payload_length,
            expected_server_modified_at_millis,
            protected_raw_envelope_reference,
            tombstone_mapping,
        })
    }
}

fn is_digest(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn is_store_identity(value: &str) -> bool {
    value.strip_prefix("obcs2.store.").is_some_and(is_digest)
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn is_protected_reference(value: &str) -> bool {
    value.strip_prefix("obcs2.ref.").is_some_and(is_digest)
}

fn semantic_stream_is_supported(stream: CloudNativeStream) -> bool {
    matches!(
        stream,
        CloudNativeStream::Chats | CloudNativeStream::Messages | CloudNativeStream::Attachments
    )
}

fn entity_kind_matches_stream(
    entity_kind: CloudCanonicalEntityKind,
    stream: CloudNativeStream,
) -> bool {
    matches!(
        (stream, entity_kind),
        (CloudNativeStream::Chats, CloudCanonicalEntityKind::Chat)
            | (
                CloudNativeStream::Messages,
                CloudCanonicalEntityKind::Message | CloudCanonicalEntityKind::Reaction
            )
            | (
                CloudNativeStream::Attachments,
                CloudCanonicalEntityKind::Attachment
            )
    )
}

fn expected_record_type(stream: CloudNativeStream) -> &'static str {
    match stream {
        CloudNativeStream::Chats => CloudChat::record_type(),
        CloudNativeStream::Messages => CloudMessage::record_type(),
        CloudNativeStream::Attachments => CloudAttachment::record_type(),
        _ => unreachable!("auxiliary streams are rejected before semantic decode"),
    }
}

fn field_name(field: &Field) -> Option<&str> {
    field.identifier.as_ref()?.name.as_deref()
}

fn record_name(record: &Record) -> Option<&str> {
    record
        .record_identifier
        .as_ref()?
        .value
        .as_ref()?
        .name
        .as_deref()
}

fn record_type(record: &Record) -> Option<&str> {
    record.r#type.as_ref()?.name.as_deref()
}

fn encrypted_field_bytes(
    record: &Record,
    key: &PCSEncryptor,
    name: &str,
) -> Result<Option<Vec<u8>>, CloudTransientBridgeFailure> {
    let Some(value) = record
        .record_field
        .iter()
        .find(|field| field_name(field) == Some(name))
        .and_then(|field| field.value.as_ref())
    else {
        return Ok(None);
    };
    let Some(ciphertext) = value.bytes_value.as_deref() else {
        return Err(CloudTransientBridgeFailure::MalformedRecord);
    };
    let decrypted = catch_unwind(AssertUnwindSafe(|| key.decrypt_data(ciphertext, name)))
        .map_err(|_| CloudTransientBridgeFailure::DecoderFailure)?;
    if decrypted.len() > MAX_DECOMPRESSED_FIELD_BYTES {
        return Err(CloudTransientBridgeFailure::OversizedRecord);
    }
    Ok(Some(decrypted))
}

fn bounded_gunzip(value: &[u8]) -> Result<Vec<u8>, CloudTransientBridgeFailure> {
    let mut decoder = GzDecoder::new(value);
    let mut output = Vec::new();
    decoder
        .by_ref()
        .take((MAX_DECOMPRESSED_FIELD_BYTES + 1) as u64)
        .read_to_end(&mut output)
        .map_err(|_| CloudTransientBridgeFailure::MalformedRecord)?;
    if output.len() > MAX_DECOMPRESSED_FIELD_BYTES {
        return Err(CloudTransientBridgeFailure::OversizedRecord);
    }
    Ok(output)
}

fn preflight_gzip_fields(
    record: &Record,
    key: &PCSEncryptor,
    fields: &[&str],
) -> Result<(), CloudTransientBridgeFailure> {
    let mut aggregate = 0usize;
    for field in fields {
        let Some(compressed) = encrypted_field_bytes(record, key, field)? else {
            continue;
        };
        let decompressed = bounded_gunzip(&compressed)?;
        aggregate = aggregate
            .checked_add(decompressed.len())
            .ok_or(CloudTransientBridgeFailure::OversizedRecord)?;
        if aggregate > MAX_DECOMPRESSED_RECORD_BYTES {
            return Err(CloudTransientBridgeFailure::OversizedRecord);
        }
    }
    Ok(())
}

fn typed_record<T: CloudKitRecord>(
    record: &Record,
    key: &PCSEncryptor,
) -> Result<T, CloudTransientBridgeFailure> {
    catch_unwind(AssertUnwindSafe(|| {
        T::from_record_encrypted(&record.record_field, Some(key))
    }))
    .map_err(|_| CloudTransientBridgeFailure::DecoderFailure)
}

fn map_native_failure(
    category: CloudNativeFailureCategory,
    safe_code: CloudNativeSafeCode,
) -> CloudTransientBridgeFailure {
    match safe_code {
        CloudNativeSafeCode::CheckpointContextMismatch => {
            CloudTransientBridgeFailure::ScopeMismatch
        }
        CloudNativeSafeCode::OversizedRecord | CloudNativeSafeCode::OversizedPage => {
            CloudTransientBridgeFailure::OversizedRecord
        }
        CloudNativeSafeCode::InvalidCheckpoint | CloudNativeSafeCode::InvalidRequest => {
            CloudTransientBridgeFailure::ProtectedReferenceMismatch
        }
        CloudNativeSafeCode::PcsUnavailable => CloudTransientBridgeFailure::PcsUnavailable,
        _ => match category {
            CloudNativeFailureCategory::Network
            | CloudNativeFailureCategory::Throttled
            | CloudNativeFailureCategory::Server => CloudTransientBridgeFailure::RetryableUpstream,
            CloudNativeFailureCategory::PcsUnavailable => {
                CloudTransientBridgeFailure::PcsUnavailable
            }
            CloudNativeFailureCategory::Authorization | CloudNativeFailureCategory::Conflict => {
                CloudTransientBridgeFailure::ScopeMismatch
            }
            CloudNativeFailureCategory::MalformedRecord => {
                CloudTransientBridgeFailure::MalformedRecord
            }
            CloudNativeFailureCategory::LocalStorage | CloudNativeFailureCategory::Unknown => {
                CloudTransientBridgeFailure::DecoderFailure
            }
        },
    }
}

fn map_push_failure(error: &PushError) -> CloudTransientBridgeFailure {
    match error {
        PushError::PCSRecordKeyMissing
        | PushError::ShareKeyNotFound(_)
        | PushError::MasterKeyNotFound
        | PushError::DecryptionKeyNotFound(_) => CloudTransientBridgeFailure::PcsUnavailable,
        PushError::RequestError(_)
        | PushError::CloudKitHttpError { .. }
        | PushError::CloudKitError(_)
        | PushError::ResourceTimeout
        | PushError::ResourceGenTimeout
        | PushError::TooManyRequests => CloudTransientBridgeFailure::RetryableUpstream,
        PushError::DoNotRetry(inner) => map_push_failure(inner),
        PushError::BatchError(inner) => map_push_failure(inner),
        _ => CloudTransientBridgeFailure::DecoderFailure,
    }
}

fn envelope_change_kind(envelope: &CloudNativeRawEnvelope) -> CloudTransientExpectedChangeKind {
    match envelope.kind() {
        CloudNativeRawEnvelopeKind::EncryptedUpsert => CloudTransientExpectedChangeKind::Save,
        CloudNativeRawEnvelopeKind::Tombstone => CloudTransientExpectedChangeKind::Delete,
        CloudNativeRawEnvelopeKind::UnsupportedRecordType
        | CloudNativeRawEnvelopeKind::MalformedMetadata => {
            CloudTransientExpectedChangeKind::Quarantined
        }
    }
}

fn bind_envelope(
    request: &CloudTransientDecodeRequest,
    envelope: &CloudNativeRawEnvelope,
    hasher: &crate::cloud_sync_semantic_decoder::CloudSemanticIdentifierHasher,
) -> Result<(), CloudTransientBridgeFailure> {
    if envelope.generation() != request.generation || envelope.stream() != request.stream {
        return Err(CloudTransientBridgeFailure::GenerationMismatch);
    }
    if envelope_change_kind(envelope) != request.expected_change_kind {
        return Err(CloudTransientBridgeFailure::ProtectedReferenceMismatch);
    }
    let record_name = envelope
        .record_name()
        .filter(|value| !value.is_empty())
        .ok_or(CloudTransientBridgeFailure::MalformedRecord)?;
    let record_id_hash = hasher
        .canonical_server_record_id_hash(record_name)
        .map_err(|_| CloudTransientBridgeFailure::MalformedRecord)?;
    let etag_hash = envelope
        .etag()
        .filter(|value| !value.is_empty())
        .map(|etag| hasher.canonical_etag_hash(etag))
        .transpose()
        .map_err(|_| CloudTransientBridgeFailure::MalformedRecord)?;
    if record_id_hash != request.expected_record_id_hash
        || etag_hash != request.expected_etag_hash
        || envelope.raw_digest_hex() != request.expected_payload_sha256
        || request
            .expected_payload_length
            .is_some_and(|length| envelope.raw_length() != length)
        || envelope.server_modified_at_millis() != request.expected_server_modified_at_millis
    {
        return Err(CloudTransientBridgeFailure::ProtectedReferenceMismatch);
    }
    let kind_tag = match request.expected_change_kind {
        CloudTransientExpectedChangeKind::Save => 1,
        CloudTransientExpectedChangeKind::Delete => 2,
        CloudTransientExpectedChangeKind::Quarantined => 3,
    };
    let material = format!(
        "{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
        request.generation,
        record_id_hash.value(),
        kind_tag,
        envelope.change_type().unwrap_or_default(),
        etag_hash
            .as_ref()
            .map(CloudCanonicalHash::value)
            .unwrap_or("none"),
        request.expected_payload_sha256,
    );
    let change_id = hasher
        .canonical_change_id_hash(&material)
        .map_err(|_| CloudTransientBridgeFailure::MalformedRecord)?;
    if change_id != request.expected_change_id {
        return Err(CloudTransientBridgeFailure::ProtectedReferenceMismatch);
    }
    Ok(())
}

fn validate_upsert_record(
    envelope: &CloudNativeRawEnvelope,
    record: &Record,
) -> Result<(), CloudTransientBridgeFailure> {
    if record_name(record) != envelope.record_name()
        || record_type(record) != envelope.record_type()
        || envelope.record_type() != Some(expected_record_type(envelope.stream()))
        || envelope.change_type().is_some_and(|value| value != 1)
    {
        return Err(CloudTransientBridgeFailure::MalformedRecord);
    }
    Ok(())
}

fn validate_tombstone_record(
    envelope: &CloudNativeRawEnvelope,
    raw: &[u8],
) -> Result<(), CloudTransientBridgeFailure> {
    let change =
        RecordChange::decode(raw).map_err(|_| CloudTransientBridgeFailure::MalformedRecord)?;
    let name = change
        .identifier
        .as_ref()
        .and_then(|identifier| identifier.value.as_ref())
        .and_then(|identifier| identifier.name.as_deref());
    let record_type = change
        .record_type
        .as_ref()
        .and_then(|record_type| record_type.name.as_deref());
    if name != envelope.record_name()
        || record_type != envelope.record_type()
        || change.r#type != envelope.change_type()
        || change.record.is_some()
        || envelope.change_type().is_some_and(|value| value != 2)
    {
        return Err(CloudTransientBridgeFailure::MalformedRecord);
    }
    Ok(())
}

fn conversion_context<'a>(
    request: &'a CloudTransientDecodeRequest,
    envelope: &'a CloudNativeRawEnvelope,
    hasher: &'a crate::cloud_sync_semantic_decoder::CloudSemanticIdentifierHasher,
    scope: &CloudNativeProtectionScope,
) -> Result<
    (
        CloudCanonicalConversionContext<'a>,
        CloudCanonicalHash,
        CloudCanonicalHash,
    ),
    CloudTransientBridgeFailure,
> {
    let scope_fingerprint = CloudCanonicalHash::new(request.expected_account_fingerprint.clone())
        .map_err(|_| CloudTransientBridgeFailure::InvalidRequest)?;
    let zone_fingerprint = hasher
        .canonical_change_id_hash(&format!("canonical-scope\u{1f}{}", scope.binding()))
        .map_err(|_| CloudTransientBridgeFailure::InvalidRequest)?;
    let record_name = envelope
        .record_name()
        .ok_or(CloudTransientBridgeFailure::MalformedRecord)?;
    Ok((
        CloudCanonicalConversionContext::new(
            hasher,
            scope_fingerprint.clone(),
            zone_fingerprint.clone(),
            request.generation,
            request.expected_change_id.clone(),
            record_name,
            envelope.etag(),
            envelope.server_created_at_millis(),
            envelope.server_modified_at_millis(),
            &request.protected_raw_envelope_reference,
        ),
        scope_fingerprint,
        zone_fingerprint,
    ))
}

fn validate_canonical_identity_bindings(
    mutation: &CloudCanonicalMutation,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<(), CloudCanonicalValidationFailure> {
    let envelope_hash = mutation.envelope().logical_entity_key_hash();
    let Some(payload) = mutation.payload() else {
        return Ok(());
    };

    let expected_hash = match payload {
        CloudCanonicalPayload::Chat(payload) => {
            for (kind, value) in [
                (CloudCanonicalAliasKind::ChatGroupId, payload.group_id()),
                (
                    CloudCanonicalAliasKind::ChatOriginalGroupId,
                    payload.original_group_id(),
                ),
                (
                    CloudCanonicalAliasKind::ChatServiceIdentifier,
                    payload.chat_identifier(),
                ),
            ] {
                let expected_alias_hash = hasher.canonical_alias_key_hash(kind, value)?;
                if !mutation
                    .envelope()
                    .aliases()
                    .iter()
                    .any(|alias| alias.kind() == kind && alias.key_hash() == &expected_alias_hash)
                {
                    return Err(CloudCanonicalValidationFailure::InvalidPayload);
                }
            }
            hasher.canonical_entity_key_hash(CloudCanonicalEntityKind::Chat, payload.guid())?
        }
        CloudCanonicalPayload::Message(payload) => {
            let expected_alias_hash = hasher.canonical_alias_key_hash(
                CloudCanonicalAliasKind::ChatServiceIdentifier,
                payload.chat_identifier(),
            )?;
            if payload.chat_alias_key_hash() != &expected_alias_hash {
                return Err(CloudCanonicalValidationFailure::InvalidPayload);
            }
            if let Some(reply) = payload.reply() {
                let expected_reply_parent = hasher.canonical_entity_key_hash(
                    CloudCanonicalEntityKind::Message,
                    reply.parent_guid(),
                )?;
                if reply.parent_hash() != &expected_reply_parent {
                    return Err(CloudCanonicalValidationFailure::InvalidPayload);
                }
            }

            match payload.association() {
                CloudCanonicalMessageAssociation::None => hasher
                    .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, payload.guid())?,
                CloudCanonicalMessageAssociation::Sticker(parent) => {
                    let expected_parent_hash = hasher.canonical_entity_key_hash(
                        CloudCanonicalEntityKind::Message,
                        parent.parent_guid(),
                    )?;
                    if parent.parent_hash() != &expected_parent_hash {
                        return Err(CloudCanonicalValidationFailure::InvalidPayload);
                    }
                    hasher.canonical_entity_key_hash(
                        CloudCanonicalEntityKind::Message,
                        payload.guid(),
                    )?
                }
                CloudCanonicalMessageAssociation::ReactionAdd { parent, .. }
                | CloudCanonicalMessageAssociation::ReactionRemove { parent, .. } => {
                    let expected_parent_hash = hasher.canonical_entity_key_hash(
                        CloudCanonicalEntityKind::Message,
                        parent.parent_guid(),
                    )?;
                    if parent.parent_hash() != &expected_parent_hash {
                        return Err(CloudCanonicalValidationFailure::InvalidPayload);
                    }
                    hasher.canonical_reaction_key_hash(
                        payload.guid(),
                        parent.parent_guid(),
                        parent.parent_part(),
                    )?
                }
            }
        }
        CloudCanonicalPayload::Attachment(payload) => {
            match (
                payload.owner_message_guid(),
                payload.owner_message_key_hash(),
                payload.owner_part(),
            ) {
                (Some(owner_guid), Some(owner_hash), Some(owner_part)) => {
                    if payload.canonical_guid() != format!("{owner_guid}_{owner_part}") {
                        return Err(CloudCanonicalValidationFailure::InvalidPayload);
                    }
                    let expected_owner_hash = hasher
                        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, owner_guid)?;
                    if owner_hash != &expected_owner_hash {
                        return Err(CloudCanonicalValidationFailure::InvalidPayload);
                    }
                    hasher.canonical_owned_attachment_key_hash(owner_guid, owner_part)?
                }
                (None, None, None) => hasher.canonical_entity_key_hash(
                    CloudCanonicalEntityKind::Attachment,
                    payload.canonical_guid(),
                )?,
                _ => return Err(CloudCanonicalValidationFailure::InvalidPayload),
            }
        }
        CloudCanonicalPayload::GroupPhoto(_) => {
            return Err(CloudCanonicalValidationFailure::InvalidPayload)
        }
    };

    if envelope_hash != &expected_hash {
        return Err(CloudCanonicalValidationFailure::InvalidPayload);
    }
    Ok(())
}

fn normalize_conversion(
    outcome: CloudCanonicalConversionOutcome,
    hasher: &CloudSemanticIdentifierHasher,
    scope_fingerprint: &CloudCanonicalHash,
    zone_fingerprint: &CloudCanonicalHash,
    generation: u64,
) -> CloudTransientDecodeOutcome {
    match outcome {
        CloudCanonicalConversionOutcome::Ready(mutation) => {
            if mutation
                .validate_active_context(scope_fingerprint, zone_fingerprint, generation)
                .is_err()
            {
                CloudTransientDecodeOutcome::Failure(
                    CloudTransientBridgeFailure::GenerationMismatch,
                )
            } else if validate_canonical_identity_bindings(&mutation, hasher).is_err() {
                CloudTransientDecodeOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::InvalidCanonicalPayload,
                )
            } else {
                CloudTransientDecodeOutcome::Ready(mutation)
            }
        }
        CloudCanonicalConversionOutcome::Deferred(reason) => {
            CloudTransientDecodeOutcome::Deferred(reason)
        }
        CloudCanonicalConversionOutcome::Quarantined(reason) => {
            CloudTransientDecodeOutcome::Quarantined(reason)
        }
    }
}

pub(crate) async fn cloud_sync_decode_transient_record(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    request: CloudTransientDecodeRequest,
) -> CloudTransientDecodeOutcome {
    let Some(storage_directory) = request.storage_directory.to_str().map(str::to_owned) else {
        return CloudTransientDecodeOutcome::Failure(CloudTransientBridgeFailure::InvalidRequest);
    };
    let actual_store_identity =
        match cloud_sync_protector::protected_store_identity(storage_directory.clone()) {
            Ok(value) => value,
            Err(_) => {
                return CloudTransientDecodeOutcome::Failure(
                    CloudTransientBridgeFailure::DecoderFailure,
                )
            }
        };
    if actual_store_identity != request.expected_protected_store_identity {
        return CloudTransientDecodeOutcome::Failure(
            CloudTransientBridgeFailure::StoreIdentityMismatch,
        );
    }
    let raw_account_identifier = cloud_messages_client.native_account_identifier().await;
    if raw_account_identifier.is_empty() {
        return CloudTransientDecodeOutcome::Failure(
            CloudTransientBridgeFailure::ActiveAccountMismatch,
        );
    }
    let actual_account_fingerprint = match cloud_sync_protector::fingerprint_account(
        storage_directory.clone(),
        raw_account_identifier,
    ) {
        Ok(value) => value,
        Err(_) => {
            return CloudTransientDecodeOutcome::Failure(
                CloudTransientBridgeFailure::DecoderFailure,
            )
        }
    };
    if actual_account_fingerprint != request.expected_account_fingerprint {
        return CloudTransientDecodeOutcome::Failure(
            CloudTransientBridgeFailure::ActiveAccountMismatch,
        );
    }
    let scope = match CloudNativeProtectionScope::new(actual_account_fingerprint, request.stream) {
        Ok(value) => value,
        Err(failure) => {
            return CloudTransientDecodeOutcome::Failure(map_native_failure(
                failure.category(),
                failure.safe_code(),
            ))
        }
    };
    let hasher = match cloud_sync_protector::semantic_identifier_hasher(storage_directory) {
        Ok(value) => value,
        Err(_) => {
            return CloudTransientDecodeOutcome::Failure(
                CloudTransientBridgeFailure::DecoderFailure,
            )
        }
    };
    let envelope = match cloud_sync_unprotect_raw_envelope(
        request.storage_directory.clone(),
        &scope,
        request.stream,
        request.generation,
        &request.protected_raw_envelope_reference,
    ) {
        Ok(value) => value,
        Err(failure) => {
            return CloudTransientDecodeOutcome::Failure(map_native_failure(
                failure.category(),
                failure.safe_code(),
            ))
        }
    };
    if let Err(failure) = bind_envelope(&request, &envelope, &hasher) {
        return CloudTransientDecodeOutcome::Failure(failure);
    }
    if matches!(
        envelope.kind(),
        CloudNativeRawEnvelopeKind::UnsupportedRecordType
            | CloudNativeRawEnvelopeKind::MalformedMetadata
    ) {
        return CloudTransientDecodeOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedRecord,
        );
    }
    let Some(raw) = envelope.raw() else {
        return CloudTransientDecodeOutcome::Failure(CloudTransientBridgeFailure::OversizedRecord);
    };
    let (context, scope_fingerprint, zone_fingerprint) =
        match conversion_context(&request, &envelope, &hasher, &scope) {
            Ok(value) => value,
            Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
        };
    if envelope.kind() == CloudNativeRawEnvelopeKind::Tombstone {
        if let Err(failure) = validate_tombstone_record(&envelope, raw) {
            return CloudTransientDecodeOutcome::Failure(failure);
        }
        let Some(mapping) = request.tombstone_mapping.as_ref() else {
            return CloudTransientDecodeOutcome::Failure(
                CloudTransientBridgeFailure::InvalidRequest,
            );
        };
        return normalize_conversion(
            convert_tombstone(
                &context,
                mapping.entity_kind,
                mapping.logical_entity_key_hash.clone(),
            ),
            &hasher,
            &scope_fingerprint,
            &zone_fingerprint,
            request.generation,
        );
    }

    let record = match Record::decode(raw).map_err(|_| CloudTransientBridgeFailure::MalformedRecord)
    {
        Ok(value) => value,
        Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
    };
    if let Err(failure) = validate_upsert_record(&envelope, &record) {
        return CloudTransientDecodeOutcome::Failure(failure);
    }
    let mut presence = match CloudRawRecordPresence::extract(&record) {
        Ok(value) => value,
        Err(_) => {
            return CloudTransientDecodeOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRecord,
            )
        }
    };
    let container = match cloud_messages_client.get_container().await {
        Ok(value) => value,
        Err(error) => {
            return CloudTransientDecodeOutcome::Failure(map_push_failure(&error));
        }
    };
    let zone = container.private_zone(request.stream.zone().to_owned());
    let zone_key = match container
        .get_zone_encryption_config(&zone, &cloud_messages_client.keychain, &MESSAGES_SERVICE)
        .await
    {
        Ok(value) => value,
        Err(error) => {
            return CloudTransientDecodeOutcome::Failure(map_push_failure(&error));
        }
    };
    let record_key =
        match catch_unwind(AssertUnwindSafe(|| pcs_keys_for_record(&record, &zone_key))) {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => {
                return CloudTransientDecodeOutcome::Failure(map_push_failure(&error));
            }
            Err(_) => {
                return CloudTransientDecodeOutcome::Failure(
                    CloudTransientBridgeFailure::DecoderFailure,
                )
            }
        };

    let converted = match request.stream {
        CloudNativeStream::Chats => {
            if let Err(failure) = preflight_gzip_fields(&record, &record_key, &["proto001"]) {
                return CloudTransientDecodeOutcome::Failure(failure);
            }
            match encrypted_field_bytes(&record, &record_key, "prop") {
                Ok(Some(decrypted)) => {
                    if presence
                        .capture_decrypted_plist_dictionary("prop", &decrypted)
                        .is_err()
                    {
                        return CloudTransientDecodeOutcome::Quarantined(
                            CloudCanonicalQuarantineReason::MalformedRecord,
                        );
                    }
                }
                Ok(None) => {}
                Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
            }
            let chat = match typed_record::<CloudChat>(&record, &record_key) {
                Ok(value) => value,
                Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
            };
            convert_chat(&context, &presence, &chat)
        }
        CloudNativeStream::Messages => {
            if let Err(failure) = preflight_gzip_fields(
                &record,
                &record_key,
                &["msgProto", "msgProto2", "msgProto3", "msgProto4"],
            ) {
                return CloudTransientDecodeOutcome::Failure(failure);
            }
            let message = match typed_record::<CloudMessage>(&record, &record_key) {
                Ok(value) => value,
                Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
            };
            convert_message(&context, &presence, &message)
        }
        CloudNativeStream::Attachments => {
            let decompressed = match encrypted_field_bytes(&record, &record_key, "cm") {
                Ok(Some(compressed)) => match bounded_gunzip(&compressed) {
                    Ok(value) => value,
                    Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
                },
                Ok(None) => {
                    return CloudTransientDecodeOutcome::Quarantined(
                        CloudCanonicalQuarantineReason::MalformedRecord,
                    )
                }
                Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
            };
            if presence
                .capture_decrypted_plist_dictionary("cm", &decompressed)
                .is_err()
            {
                return CloudTransientDecodeOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::MalformedRecord,
                );
            }
            let attachment = match typed_record::<CloudAttachment>(&record, &record_key) {
                Ok(value) => value,
                Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
            };
            convert_attachment(&context, &presence, &attachment.cm.0)
        }
        CloudNativeStream::MessageUpdate
        | CloudNativeStream::RecoverableMessageDelete
        | CloudNativeStream::ScheduledMessage
        | CloudNativeStream::Chat1 => {
            return CloudTransientDecodeOutcome::Failure(
                CloudTransientBridgeFailure::DecoderFailure,
            );
        }
    };
    normalize_conversion(
        converted,
        &hasher,
        &scope_fingerprint,
        &zone_fingerprint,
        request.generation,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_canonical_dto::{
        parse_associated_parent, CloudCanonicalAlias, CloudCanonicalAttachmentPayload,
        CloudCanonicalChatPayload, CloudCanonicalChatStyle, CloudCanonicalEnvelope,
        CloudCanonicalField, CloudCanonicalKnownMessageFlags, CloudCanonicalMessageAssociation,
        CloudCanonicalMessagePayload, CloudCanonicalMutationKind, CloudCanonicalParentReference,
        CloudCanonicalPayload, CloudCanonicalProtectedReference, CloudCanonicalReactionKind,
        CloudCanonicalService, CloudCanonicalSnapshot, CLOUD_CANONICAL_SCHEMA_VERSION,
    };

    fn digest(character: char) -> String {
        character.to_string().repeat(43)
    }

    fn upsert_mutation(
        entity_kind: CloudCanonicalEntityKind,
        logical_hash: CloudCanonicalHash,
        parent_hash: Option<CloudCanonicalHash>,
        payload: CloudCanonicalPayload,
    ) -> CloudCanonicalMutation {
        let protected_reference =
            CloudCanonicalProtectedReference::new("obcs2.test-reference").unwrap();
        let envelope = CloudCanonicalEnvelope::new(
            CloudCanonicalHash::new(digest('s')).unwrap(),
            CloudCanonicalHash::new(digest('z')).unwrap(),
            7,
            CLOUD_CANONICAL_SCHEMA_VERSION,
            CloudCanonicalHash::new(digest('c')).unwrap(),
            entity_kind,
            CloudCanonicalMutationKind::Upsert,
            CloudCanonicalHash::new(digest('r')).unwrap(),
            logical_hash.clone(),
            parent_hash.clone(),
            Vec::new(),
            None,
            None,
            None,
            protected_reference.clone(),
        )
        .unwrap();
        let snapshot = CloudCanonicalSnapshot::new(
            entity_kind,
            logical_hash,
            parent_hash,
            None,
            None,
            None,
            None,
            Vec::new(),
            None,
            None,
            None,
            None,
            protected_reference,
        )
        .unwrap();
        CloudCanonicalMutation::new(envelope, Some(snapshot), Some(payload), None).unwrap()
    }

    fn message_payload(
        hasher: &CloudSemanticIdentifierHasher,
        guid: &str,
        chat_alias_hash: Option<CloudCanonicalHash>,
        association: CloudCanonicalMessageAssociation,
    ) -> CloudCanonicalPayload {
        let chat_alias_hash = chat_alias_hash.unwrap_or_else(|| {
            hasher
                .canonical_alias_key_hash(
                    CloudCanonicalAliasKind::ChatServiceIdentifier,
                    "iMessage;-;+15555550100",
                )
                .unwrap()
        });
        let is_reaction = association.is_reaction();
        CloudCanonicalPayload::Message(Box::new(
            CloudCanonicalMessagePayload::new(
                guid.to_owned(),
                "iMessage;-;+15555550100".to_owned(),
                chat_alias_hash,
                "sender@example.invalid".to_owned(),
                1,
                0,
                CloudCanonicalService::IMessage,
                CloudCanonicalField::Absent,
                if is_reaction {
                    CloudCanonicalField::Absent
                } else {
                    CloudCanonicalField::Value("body".to_owned())
                },
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalKnownMessageFlags::default(),
                association,
                None,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
            )
            .unwrap(),
        ))
    }

    fn message_mutation(
        hasher: &CloudSemanticIdentifierHasher,
        logical_hash_override: Option<CloudCanonicalHash>,
        chat_alias_hash_override: Option<CloudCanonicalHash>,
    ) -> CloudCanonicalMutation {
        let payload = message_payload(
            hasher,
            "message-guid",
            chat_alias_hash_override,
            CloudCanonicalMessageAssociation::None,
        );
        let logical_hash = logical_hash_override.unwrap_or_else(|| {
            hasher
                .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, "message-guid")
                .unwrap()
        });
        upsert_mutation(
            CloudCanonicalEntityKind::Message,
            logical_hash,
            None,
            payload,
        )
    }

    fn reaction_mutation(
        hasher: &CloudSemanticIdentifierHasher,
        wire_parent: &str,
        logical_hash_override: Option<CloudCanonicalHash>,
        parent_hash_override: Option<CloudCanonicalHash>,
    ) -> CloudCanonicalMutation {
        let parsed = parse_associated_parent(wire_parent).unwrap();
        let expected_parent_hash = hasher
            .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, parsed.parent_guid())
            .unwrap();
        let parent_hash = parent_hash_override.unwrap_or_else(|| expected_parent_hash.clone());
        let parent = CloudCanonicalParentReference::new(
            parsed.parent_guid().to_owned(),
            parsed.parent_part(),
            parent_hash.clone(),
            None,
            None,
        )
        .unwrap();
        let association = CloudCanonicalMessageAssociation::ReactionAdd {
            kind: CloudCanonicalReactionKind::Heart,
            parent,
        };
        let expected_logical_hash = hasher
            .canonical_reaction_key_hash(
                "reaction-guid",
                parsed.parent_guid(),
                parsed.parent_part(),
            )
            .unwrap();
        let logical_hash = logical_hash_override.unwrap_or(expected_logical_hash);
        let payload = message_payload(hasher, "reaction-guid", None, association);
        upsert_mutation(
            CloudCanonicalEntityKind::Reaction,
            logical_hash,
            Some(parent_hash),
            payload,
        )
    }

    fn attachment_mutation(
        hasher: &CloudSemanticIdentifierHasher,
        canonical_guid: &str,
        owner: Option<(&str, u32)>,
        owner_hash_override: Option<CloudCanonicalHash>,
        logical_hash_override: Option<CloudCanonicalHash>,
    ) -> CloudCanonicalMutation {
        let (owner_message_guid, owner_part, expected_logical_hash, expected_owner_hash) =
            match owner {
                Some((owner_guid, part)) => (
                    Some(owner_guid.to_owned()),
                    Some(part),
                    hasher
                        .canonical_owned_attachment_key_hash(owner_guid, part)
                        .unwrap(),
                    Some(
                        hasher
                            .canonical_entity_key_hash(
                                CloudCanonicalEntityKind::Message,
                                owner_guid,
                            )
                            .unwrap(),
                    ),
                ),
                None => (
                    None,
                    None,
                    hasher
                        .canonical_entity_key_hash(
                            CloudCanonicalEntityKind::Attachment,
                            canonical_guid,
                        )
                        .unwrap(),
                    None,
                ),
            };
        let owner_hash = owner_hash_override.or(expected_owner_hash);
        let payload = CloudCanonicalPayload::Attachment(Box::new(
            CloudCanonicalAttachmentPayload::new(
                canonical_guid.to_owned(),
                owner_message_guid,
                owner_hash.clone(),
                owner_part,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Absent,
                CloudCanonicalField::Value(0),
                CloudCanonicalField::Value(false),
                CloudCanonicalField::Absent,
            )
            .unwrap(),
        ));
        upsert_mutation(
            CloudCanonicalEntityKind::Attachment,
            logical_hash_override.unwrap_or(expected_logical_hash),
            owner_hash,
            payload,
        )
    }

    fn chat_mutation(
        hasher: &CloudSemanticIdentifierHasher,
        logical_hash: CloudCanonicalHash,
        tamper_service_alias: bool,
    ) -> CloudCanonicalMutation {
        let protected_reference =
            CloudCanonicalProtectedReference::new("obcs2.test-reference").unwrap();
        let aliases = [
            (CloudCanonicalAliasKind::ChatGroupId, "group-id"),
            (
                CloudCanonicalAliasKind::ChatOriginalGroupId,
                "original-group-id",
            ),
            (
                CloudCanonicalAliasKind::ChatServiceIdentifier,
                "iMessage;-;+15555550100",
            ),
        ]
        .into_iter()
        .map(|(kind, value)| {
            let key_hash =
                if tamper_service_alias && kind == CloudCanonicalAliasKind::ChatServiceIdentifier {
                    CloudCanonicalHash::new(digest('a')).unwrap()
                } else {
                    hasher.canonical_alias_key_hash(kind, value).unwrap()
                };
            CloudCanonicalAlias::new(kind, key_hash)
        })
        .collect();
        let envelope = CloudCanonicalEnvelope::new(
            CloudCanonicalHash::new(digest('s')).unwrap(),
            CloudCanonicalHash::new(digest('z')).unwrap(),
            7,
            CLOUD_CANONICAL_SCHEMA_VERSION,
            CloudCanonicalHash::new(digest('c')).unwrap(),
            CloudCanonicalEntityKind::Chat,
            CloudCanonicalMutationKind::Upsert,
            CloudCanonicalHash::new(digest('r')).unwrap(),
            logical_hash.clone(),
            None,
            aliases,
            None,
            None,
            None,
            protected_reference.clone(),
        )
        .unwrap();
        let snapshot = CloudCanonicalSnapshot::new(
            CloudCanonicalEntityKind::Chat,
            logical_hash,
            None,
            None,
            None,
            None,
            None,
            Vec::new(),
            None,
            None,
            None,
            None,
            protected_reference,
        )
        .unwrap();
        let payload = CloudCanonicalChatPayload::new(
            "chat-guid".to_owned(),
            "iMessage;-;+15555550100".to_owned(),
            "group-id".to_owned(),
            "original-group-id".to_owned(),
            CloudCanonicalService::IMessage,
            CloudCanonicalChatStyle::Direct,
            vec!["tel:+15555550100".to_owned()],
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .unwrap();
        CloudCanonicalMutation::new(
            envelope,
            Some(snapshot),
            Some(CloudCanonicalPayload::Chat(Box::new(payload))),
            None,
        )
        .unwrap()
    }

    #[test]
    fn canonical_identity_validator_recomputes_before_dart_handoff() {
        let hasher = CloudSemanticIdentifierHasher::new(b"bridge-identity-test").unwrap();
        let valid_hash = hasher
            .canonical_entity_key_hash(CloudCanonicalEntityKind::Chat, "chat-guid")
            .unwrap();
        assert_eq!(
            validate_canonical_identity_bindings(
                &chat_mutation(&hasher, valid_hash.clone(), false),
                &hasher
            ),
            Ok(())
        );

        assert_eq!(
            validate_canonical_identity_bindings(
                &chat_mutation(&hasher, valid_hash, true),
                &hasher
            ),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );

        let tampered_hash = CloudCanonicalHash::new(digest('t')).unwrap();
        assert_eq!(
            validate_canonical_identity_bindings(
                &chat_mutation(&hasher, tampered_hash, false),
                &hasher
            ),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );
    }

    #[test]
    fn canonical_message_identity_tampering_is_rejected_before_dart_handoff() {
        let hasher = CloudSemanticIdentifierHasher::new(b"message-identity-test").unwrap();
        let valid = message_mutation(&hasher, None, None);
        assert_eq!(
            validate_canonical_identity_bindings(&valid, &hasher),
            Ok(())
        );

        let wrong_logical_hash = CloudCanonicalHash::new(digest('m')).unwrap();
        assert_eq!(
            validate_canonical_identity_bindings(
                &message_mutation(&hasher, Some(wrong_logical_hash), None),
                &hasher,
            ),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );

        let wrong_chat_alias_hash = CloudCanonicalHash::new(digest('a')).unwrap();
        assert_eq!(
            validate_canonical_identity_bindings(
                &message_mutation(&hasher, None, Some(wrong_chat_alias_hash)),
                &hasher,
            ),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );
    }

    #[test]
    fn canonical_reaction_identity_preserves_parent_part_semantics_and_rejects_tampering() {
        let hasher = CloudSemanticIdentifierHasher::new(b"reaction-identity-test").unwrap();
        let partless = reaction_mutation(&hasher, "parent-guid", None, None);
        let part_zero = reaction_mutation(&hasher, "p:0/parent-guid", None, None);
        let bubble_part_zero = reaction_mutation(&hasher, "bp:0/parent-guid", None, None);

        assert_eq!(
            validate_canonical_identity_bindings(&partless, &hasher),
            Ok(())
        );
        assert_eq!(
            validate_canonical_identity_bindings(&part_zero, &hasher),
            Ok(())
        );
        assert_eq!(
            validate_canonical_identity_bindings(&bubble_part_zero, &hasher),
            Ok(())
        );
        assert_ne!(
            hasher
                .canonical_reaction_key_hash("reaction-guid", "parent-guid", None)
                .unwrap(),
            hasher
                .canonical_reaction_key_hash("reaction-guid", "parent-guid", Some(0))
                .unwrap()
        );

        let wrong_logical_hash = hasher
            .canonical_reaction_key_hash("reaction-guid", "parent-guid", Some(0))
            .unwrap();
        assert_eq!(
            validate_canonical_identity_bindings(
                &reaction_mutation(&hasher, "parent-guid", Some(wrong_logical_hash), None),
                &hasher,
            ),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );

        let wrong_parent_hash = CloudCanonicalHash::new(digest('p')).unwrap();
        assert_eq!(
            validate_canonical_identity_bindings(
                &reaction_mutation(&hasher, "p:0/parent-guid", None, Some(wrong_parent_hash)),
                &hasher,
            ),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );
    }

    #[test]
    fn canonical_owned_attachment_identity_tampering_is_rejected_before_dart_handoff() {
        let hasher = CloudSemanticIdentifierHasher::new(b"owned-attachment-test").unwrap();
        let valid = attachment_mutation(
            &hasher,
            "message_guid_with_underscores_7",
            Some(("message_guid_with_underscores", 7)),
            None,
            None,
        );
        assert_eq!(
            validate_canonical_identity_bindings(&valid, &hasher),
            Ok(())
        );

        let wrong_canonical_guid = attachment_mutation(
            &hasher,
            "wrong-guid",
            Some(("message_guid_with_underscores", 7)),
            None,
            None,
        );
        assert_eq!(
            validate_canonical_identity_bindings(&wrong_canonical_guid, &hasher),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );

        let wrong_owner_hash = CloudCanonicalHash::new(digest('o')).unwrap();
        let tampered_owner = attachment_mutation(
            &hasher,
            "message_guid_with_underscores_7",
            Some(("message_guid_with_underscores", 7)),
            Some(wrong_owner_hash),
            None,
        );
        assert_eq!(
            validate_canonical_identity_bindings(&tampered_owner, &hasher),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );
    }

    #[test]
    fn canonical_bare_attachment_identity_tampering_is_rejected_before_dart_handoff() {
        let hasher = CloudSemanticIdentifierHasher::new(b"bare-attachment-test").unwrap();
        let valid = attachment_mutation(&hasher, "bare-attachment-guid", None, None, None);
        assert_eq!(
            validate_canonical_identity_bindings(&valid, &hasher),
            Ok(())
        );

        let wrong_logical_hash = CloudCanonicalHash::new(digest('b')).unwrap();
        let tampered = attachment_mutation(
            &hasher,
            "bare-attachment-guid",
            None,
            None,
            Some(wrong_logical_hash),
        );
        assert_eq!(
            validate_canonical_identity_bindings(&tampered, &hasher),
            Err(CloudCanonicalValidationFailure::InvalidPayload)
        );
    }

    #[test]
    fn request_rejects_cross_scope_and_incomplete_tombstone_mapping() {
        let result = CloudTransientDecodeRequest::new(
            PathBuf::from("missing"),
            digest('a'),
            format!("obcs2.store.{}", digest('b')),
            "com.apple.messages.cloud".to_owned(),
            "private".to_owned(),
            "messageManateeZone".to_owned(),
            "messages".to_owned(),
            2,
            CloudNativeStream::Messages,
            7,
            CloudTransientExpectedChangeKind::Delete,
            digest('c'),
            digest('d'),
            None,
            "e".repeat(64),
            Some(1),
            None,
            format!("obcs2.ref.{}", digest('f')),
            None,
        );
        assert_eq!(
            result.err(),
            Some(CloudTransientBridgeFailure::InvalidRequest)
        );
    }

    #[test]
    fn request_rejects_scope_zone_and_reference_confusion() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let result = CloudTransientDecodeRequest::new(
            directory.path().to_path_buf(),
            digest('a'),
            format!("obcs2.store.{}", digest('b')),
            "com.apple.messages.cloud".to_owned(),
            "private".to_owned(),
            "chatManateeZone".to_owned(),
            "messages".to_owned(),
            2,
            CloudNativeStream::Messages,
            7,
            CloudTransientExpectedChangeKind::Save,
            digest('c'),
            digest('d'),
            None,
            "e".repeat(64),
            Some(1),
            None,
            format!("obcs2.ref.{}", digest('f')),
            None,
        );
        assert_eq!(
            result.err(),
            Some(CloudTransientBridgeFailure::InvalidRequest)
        );
    }

    #[test]
    fn request_rejects_auxiliary_streams_before_semantic_decode() {
        let directory = tempfile::tempdir().expect("temporary directory");
        for stream in [
            CloudNativeStream::MessageUpdate,
            CloudNativeStream::RecoverableMessageDelete,
            CloudNativeStream::ScheduledMessage,
            CloudNativeStream::Chat1,
        ] {
            let result = CloudTransientDecodeRequest::new(
                directory.path().to_path_buf(),
                digest('a'),
                format!("obcs2.store.{}", digest('b')),
                "com.apple.messages.cloud".to_owned(),
                "private".to_owned(),
                stream.zone().to_owned(),
                "messages".to_owned(),
                2,
                stream,
                7,
                CloudTransientExpectedChangeKind::Save,
                digest('c'),
                digest('d'),
                None,
                "e".repeat(64),
                Some(1),
                None,
                format!("obcs2.ref.{}", digest('f')),
                None,
            );
            assert_eq!(
                result.err(),
                Some(CloudTransientBridgeFailure::InvalidRequest)
            );
        }
    }

    #[test]
    fn bounded_gzip_rejects_malformed_input_without_panicking() {
        assert_eq!(
            bounded_gunzip(b"not-gzip").unwrap_err(),
            CloudTransientBridgeFailure::MalformedRecord
        );
    }

    #[test]
    fn debug_output_never_contains_content() {
        let secret = "private-message-content";
        let output = format!(
            "{:?}",
            CloudTransientDecodeOutcome::Failure(CloudTransientBridgeFailure::DecoderFailure)
        );
        assert!(!output.contains(secret));
        assert!(!format!("{:?}", CloudTransientBridgeFailure::DecoderFailure).contains(secret));
    }

    #[test]
    fn protected_reference_and_digest_grammars_are_closed() {
        assert!(is_digest(&digest('a')));
        assert!(is_store_identity(&format!("obcs2.store.{}", digest('b'))));
        assert!(is_protected_reference(&format!(
            "obcs2.ref.{}",
            digest('c')
        )));
        assert!(is_sha256_hex(&"d".repeat(64)));
        assert!(!is_protected_reference("obcs2.ref.apple-record-name"));
        assert!(!is_sha256_hex(&"G".repeat(64)));
    }

    #[test]
    fn tombstone_entity_kind_is_stream_fenced() {
        assert!(entity_kind_matches_stream(
            CloudCanonicalEntityKind::Reaction,
            CloudNativeStream::Messages
        ));
        assert!(!entity_kind_matches_stream(
            CloudCanonicalEntityKind::Chat,
            CloudNativeStream::Messages
        ));
        assert!(!entity_kind_matches_stream(
            CloudCanonicalEntityKind::GroupPhoto,
            CloudNativeStream::Chats
        ));
    }
}
