//! Default-off D1 Cloud Sync semantic conversion boundary.
//!
//! The D0 journal supplies only protected capabilities and content-free
//! digests. This module validates the complete active account/scope/generation
//! and native-store fence, unprotects one raw record inside Rust, decrypts it,
//! and invokes the canonical converter. Raw Apple identifiers, PCS material,
//! and CloudKit records never cross Flutter Rust Bridge.

#![allow(dead_code)]

use std::{
    io::{Cursor, Read},
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    sync::Arc,
};

use crate::{
    cloud_sync_canonical_converter::{
        convert_attachment, convert_chat_with_diagnostic, convert_message, convert_tombstone,
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
        MAX_RAW_RECORD_BYTES,
    },
    cloud_sync_protector,
    cloud_sync_semantic_identity::CloudSemanticIdentifierHasher,
};
use flate2::bufread::GzDecoder;
use log::warn;
use prost::Message as _;
use rustpush::{
    cloud_messages::{
        cloudmessagesp::{ChatProto, MessageProto, MessageProto2, MessageProto3, MessageProto4},
        CloudAttachment, CloudChat, CloudMessage, CloudMessagesClient, CloudParticipant,
        MESSAGES_SERVICE,
    },
    cloudkit::{classify_cloudkit_failure, pcs_keys_for_record, CloudKitFailureClass},
    cloudkit_operation_gate::CloudKitReadAuthenticationPermit,
    cloudkit_proto::{
        record::{
            field::{value::Type as FieldValueType, Value},
            Field,
        },
        retrieve_changes_response::RecordChange,
        CloudKitEncryptor, CloudKitRecord, Record,
    },
    pcs::PCSEncryptor,
    DefaultAnisetteProvider, PushError,
};

const MAX_DECOMPRESSED_FIELD_BYTES: usize = 16 * 1024 * 1024;
const MAX_DECOMPRESSED_RECORD_BYTES: usize = 32 * 1024 * 1024;
const MAX_ENCRYPTED_VALUE_NESTING_DEPTH: usize = 64;
const MAX_PARTICIPANT_COUNT: usize = 4 * 1024;
const MAX_PARTICIPANT_PLAINTEXT_BYTES: usize = MAX_DECOMPRESSED_RECORD_BYTES;

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
    WarmAuthenticationRequired,
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

/// Emits only the fixed decoder stage, never record content or identifiers.
/// `DecoderFailure` otherwise collapses unrelated native failures into one
/// opaque result, which makes an authenticated canary unable to distinguish
/// PCS setup from field decoding without exposing protected data.
fn decoder_failure_at(stage: &'static str) -> CloudTransientBridgeFailure {
    warn!("CloudKit V2 transient decoder stage={stage}");
    CloudTransientBridgeFailure::DecoderFailure
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

#[derive(Clone)]
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

fn missing_raw_failure(raw_length: u64) -> CloudTransientBridgeFailure {
    if raw_length > MAX_RAW_RECORD_BYTES as u64 {
        CloudTransientBridgeFailure::OversizedRecord
    } else {
        CloudTransientBridgeFailure::MalformedRecord
    }
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
    validate_encrypted_bytes_value(value)?;
    let Some(ciphertext) = value.bytes_value.as_deref() else {
        return Err(CloudTransientBridgeFailure::MalformedRecord);
    };
    let decrypted = key
        .decrypt_data_checked(ciphertext, name)
        .map_err(|error| map_push_failure_at(&error, "field_decrypt"))?;
    if decrypted.len() > MAX_DECOMPRESSED_FIELD_BYTES {
        return Err(CloudTransientBridgeFailure::OversizedRecord);
    }
    Ok(Some(decrypted))
}

fn validate_encrypted_bytes_value(value: &Value) -> Result<(), CloudTransientBridgeFailure> {
    if value.r#type != Some(FieldValueType::EncryptedBytesType as i32)
        || value.is_encrypted == Some(false)
    {
        return Err(CloudTransientBridgeFailure::MalformedRecord);
    }
    Ok(())
}

fn preflight_ciphertext_key(
    key: &PCSEncryptor,
    ciphertext: &[u8],
) -> Result<(), CloudTransientBridgeFailure> {
    key.validate_ciphertext_key(ciphertext)
        .map_err(|error| map_push_failure_at(&error, "ciphertext_key_preflight"))
}

fn preflight_encrypted_value_keys(
    key: &PCSEncryptor,
    value: &Value,
) -> Result<(), CloudTransientBridgeFailure> {
    preflight_encrypted_value_keys_at_depth(key, value, 0)
}

fn preflight_encrypted_value_keys_at_depth(
    key: &PCSEncryptor,
    value: &Value,
    depth: usize,
) -> Result<(), CloudTransientBridgeFailure> {
    if depth > MAX_ENCRYPTED_VALUE_NESTING_DEPTH {
        return Err(CloudTransientBridgeFailure::OversizedRecord);
    }
    if value.is_encrypted == Some(true) {
        let ciphertext = value
            .bytes_value
            .as_deref()
            .ok_or(CloudTransientBridgeFailure::MalformedRecord)?;
        preflight_ciphertext_key(key, ciphertext)?;
    }
    for nested in &value.list_values {
        preflight_encrypted_value_keys_at_depth(key, nested, depth + 1)?;
    }
    if let Some(asset) = value.asset_value.as_ref() {
        if let Some(ciphertext) = asset
            .protection_info
            .as_ref()
            .and_then(|protection| protection.protection_info.as_deref())
        {
            preflight_ciphertext_key(key, ciphertext)?;
        }
    }
    Ok(())
}

fn preflight_record_ciphertext_keys(
    record: &Record,
    key: &PCSEncryptor,
) -> Result<(), CloudTransientBridgeFailure> {
    for field in &record.record_field {
        if let Some(value) = field.value.as_ref() {
            preflight_encrypted_value_keys(key, value)?;
        }
    }
    Ok(())
}

/// V2 must not inherit the legacy encryptor's `unwrap_or_default` behavior.
/// The derived record decoder catches panics and returns a typed error, so a
/// content-free panic here converts every PCS failure into fail-closed
/// `DecoderFailure` without exposing plaintext or ciphertext.
struct StrictCloudKitV2Decryptor<'a> {
    inner: &'a PCSEncryptor,
}

impl CloudKitEncryptor for StrictCloudKitV2Decryptor<'_> {
    fn decrypt_data(&self, data: &[u8], field_name: &str) -> Vec<u8> {
        self.inner
            .decrypt_data_checked(data, field_name)
            .unwrap_or_else(|_| panic!("CloudKit V2 PCS decryption failed"))
    }

    fn encrypt_data(&self, _: &[u8], _: &str) -> Vec<u8> {
        panic!("CloudKit V2 semantic decoder attempted encryption")
    }
}

#[derive(Clone, Copy)]
struct GzipFieldSpec {
    name: &'static str,
    required: bool,
    decoder_stage: &'static str,
    decode: fn(&[u8]) -> Result<(), ()>,
}

impl GzipFieldSpec {
    const fn required(
        name: &'static str,
        decoder_stage: &'static str,
        decode: fn(&[u8]) -> Result<(), ()>,
    ) -> Self {
        Self {
            name,
            required: true,
            decoder_stage,
            decode,
        }
    }

    const fn optional(
        name: &'static str,
        decoder_stage: &'static str,
        decode: fn(&[u8]) -> Result<(), ()>,
    ) -> Self {
        Self {
            name,
            required: false,
            decoder_stage,
            decode,
        }
    }
}

fn decode_chat_proto(value: &[u8]) -> Result<(), ()> {
    ChatProto::decode(value).map(|_| ()).map_err(|_| ())
}

fn decode_message_proto(value: &[u8]) -> Result<(), ()> {
    MessageProto::decode(value).map(|_| ()).map_err(|_| ())
}

fn decode_message_proto_2(value: &[u8]) -> Result<(), ()> {
    MessageProto2::decode(value).map(|_| ()).map_err(|_| ())
}

fn decode_message_proto_3(value: &[u8]) -> Result<(), ()> {
    MessageProto3::decode(value).map(|_| ()).map_err(|_| ())
}

fn decode_message_proto_4(value: &[u8]) -> Result<(), ()> {
    MessageProto4::decode(value).map(|_| ()).map_err(|_| ())
}

fn validate_nested_protobuf(
    value: &[u8],
    field: GzipFieldSpec,
) -> Result<(), CloudTransientBridgeFailure> {
    match catch_unwind(AssertUnwindSafe(|| (field.decode)(value))) {
        Ok(Ok(())) => Ok(()),
        Ok(Err(())) => Err(decoder_failure_at(field.decoder_stage)),
        Err(_) => Err(decoder_failure_at("nested_protobuf_panic")),
    }
}

/// Returns whether a gzip field needs decrypt/decompress preflight.
///
/// Apple encodes some absent optional encrypted protobuf fields as the
/// `EMPTY_LIST` wire sentinel. The typed CloudKit decoder already maps that
/// sentinel to `None`, but attempting to decrypt it first treated the missing
/// ciphertext as a malformed record. Required fields remain strict, and every
/// other present non-bytes shape remains malformed.
fn gzip_field_requires_preflight(
    record: &Record,
    presence: &CloudRawRecordPresence,
    field: GzipFieldSpec,
) -> Result<bool, CloudTransientBridgeFailure> {
    let Some(candidate) = record
        .record_field
        .iter()
        .find(|candidate| field_name(candidate) == Some(field.name))
    else {
        return if field.required {
            Err(CloudTransientBridgeFailure::MalformedRecord)
        } else {
            Ok(false)
        };
    };
    let Some(value) = candidate.value.as_ref() else {
        return Err(CloudTransientBridgeFailure::MalformedRecord);
    };
    if !field.required && presence.was_sent_as_empty_list(field.name) {
        if value.bytes_value.is_some()
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
            return Err(CloudTransientBridgeFailure::MalformedRecord);
        }
        return Ok(false);
    }
    validate_encrypted_bytes_value(value)?;
    if value.bytes_value.is_none() {
        return Err(CloudTransientBridgeFailure::MalformedRecord);
    }
    Ok(true)
}

fn bounded_gunzip(value: &[u8]) -> Result<Vec<u8>, CloudTransientBridgeFailure> {
    let mut decoder = GzDecoder::new(Cursor::new(value));
    let mut output = Vec::new();
    decoder
        .by_ref()
        .take((MAX_DECOMPRESSED_FIELD_BYTES + 1) as u64)
        .read_to_end(&mut output)
        .map_err(|_| CloudTransientBridgeFailure::MalformedRecord)?;
    if output.len() > MAX_DECOMPRESSED_FIELD_BYTES {
        return Err(CloudTransientBridgeFailure::OversizedRecord);
    }
    if decoder.into_inner().position() as usize != value.len() {
        return Err(CloudTransientBridgeFailure::MalformedRecord);
    }
    Ok(output)
}

fn normalize_optional_empty_gzip_field(
    record: &mut Record,
    field: GzipFieldSpec,
    decrypted: &[u8],
) -> bool {
    if field.required || !decrypted.is_empty() {
        return false;
    }
    record
        .record_field
        .retain(|candidate| field_name(candidate) != Some(field.name));
    true
}

fn empty_list_value_is_payload_free(value: &Value) -> bool {
    value.bytes_value.is_none()
        && value.signed_value.is_none()
        && value.double_value.is_none()
        && value.date_value.is_none()
        && value.string_value.is_none()
        && value.location_value.is_none()
        && value.reference_value.is_none()
        && value.asset_value.is_none()
        && value.list_values.is_empty()
        && value.package_value.is_none()
}

/// Removes only schema-known optional fields represented by Apple's
/// payload-free `EMPTY_LIST` sentinel. Raw presence is captured before this
/// normalization, so canonical conversion still distinguishes absence from an
/// explicit empty sentinel.
fn normalize_optional_empty_list_fields(
    record: &mut Record,
    presence: &CloudRawRecordPresence,
    optional_fields: &[&str],
) -> Result<(), CloudTransientBridgeFailure> {
    for field in optional_fields {
        if !presence.was_sent_as_empty_list(field) {
            continue;
        }
        let candidate = record
            .record_field
            .iter()
            .find(|candidate| field_name(candidate) == Some(field))
            .ok_or(CloudTransientBridgeFailure::MalformedRecord)?;
        let value = candidate
            .value
            .as_ref()
            .ok_or(CloudTransientBridgeFailure::MalformedRecord)?;
        if !empty_list_value_is_payload_free(value) {
            return Err(CloudTransientBridgeFailure::MalformedRecord);
        }
        record
            .record_field
            .retain(|candidate| field_name(candidate) != Some(field));
    }
    Ok(())
}

fn non_gzip_header_stage(value: &[u8]) -> &'static str {
    match value {
        [] => "header_empty",
        [_] => "header_single_byte",
        [cmf, flg, ..] if cmf & 0x0f == 8 && (u16::from(*cmf) << 8 | u16::from(*flg)) % 31 == 0 => {
            "header_zlib"
        }
        _ => "header_non_gzip",
    }
}

fn preflight_gzip_fields(
    record: &mut Record,
    key: &PCSEncryptor,
    presence: &CloudRawRecordPresence,
    fields: &[GzipFieldSpec],
) -> Result<(), CloudTransientBridgeFailure> {
    let mut aggregate = 0usize;
    for field in fields {
        let requires_preflight = match gzip_field_requires_preflight(record, presence, *field) {
            Ok(value) => value,
            Err(failure) => {
                warn!(
                    "CloudKit V2 gzip preflight field={} stage=wire_shape",
                    field.name
                );
                return Err(failure);
            }
        };
        if !requires_preflight {
            continue;
        }
        let compressed = match encrypted_field_bytes(record, key, field.name) {
            Ok(Some(value)) => value,
            Ok(None) => {
                warn!(
                    "CloudKit V2 gzip preflight field={} stage=missing_ciphertext",
                    field.name
                );
                return Err(CloudTransientBridgeFailure::MalformedRecord);
            }
            Err(failure) => {
                warn!(
                    "CloudKit V2 gzip preflight field={} stage=decrypt",
                    field.name
                );
                return Err(failure);
            }
        };
        // Zero-length plaintext cannot carry an optional protobuf. Normalize
        // only that exact, unambiguous shape to absence before the typed decoder
        // reaches its infallible gzip wrapper. Required fields remain strict,
        // and every non-empty non-gzip value still fails closed.
        if normalize_optional_empty_gzip_field(record, *field, &compressed) {
            warn!(
                "CloudKit V2 gzip preflight field={} stage=optional_empty_normalized",
                field.name
            );
            continue;
        }
        if compressed.len() < 2 || compressed[..2] != [0x1f, 0x8b] {
            let stage = non_gzip_header_stage(&compressed);
            warn!(
                "CloudKit V2 gzip preflight field={} stage={stage}",
                field.name
            );
            return Err(CloudTransientBridgeFailure::MalformedRecord);
        }
        let decompressed = match bounded_gunzip(&compressed) {
            Ok(value) => value,
            Err(failure) => {
                let stage = if failure == CloudTransientBridgeFailure::OversizedRecord {
                    "field_oversized"
                } else {
                    "inflate"
                };
                warn!(
                    "CloudKit V2 gzip preflight field={} stage={stage}",
                    field.name
                );
                return Err(failure);
            }
        };
        aggregate = aggregate
            .checked_add(decompressed.len())
            .ok_or(CloudTransientBridgeFailure::OversizedRecord)?;
        if aggregate > MAX_DECOMPRESSED_RECORD_BYTES {
            warn!(
                "CloudKit V2 gzip preflight field={} stage=record_oversized",
                field.name
            );
            return Err(CloudTransientBridgeFailure::OversizedRecord);
        }
        validate_nested_protobuf(&decompressed, *field)?;
    }
    Ok(())
}

fn decode_cloud_chat_record<E: CloudKitEncryptor>(
    record: &Record,
    key: &E,
) -> Result<CloudChat, CloudTransientBridgeFailure> {
    match catch_unwind(AssertUnwindSafe(|| {
        CloudChat::try_from_record_encrypted(&record.record_field, Some(key))
    })) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(_)) => Err(decoder_failure_at("typed_chat")),
        Err(_) => Err(decoder_failure_at("typed_chat_panic")),
    }
}

fn decode_cloud_message_record<E: CloudKitEncryptor>(
    record: &Record,
    key: &E,
) -> Result<CloudMessage, CloudTransientBridgeFailure> {
    match catch_unwind(AssertUnwindSafe(|| {
        CloudMessage::try_from_record_encrypted(&record.record_field, Some(key))
    })) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(_)) => Err(decoder_failure_at("typed_message")),
        Err(_) => Err(decoder_failure_at("typed_message_panic")),
    }
}

fn decode_cloud_attachment_record<E: CloudKitEncryptor>(
    record: &Record,
    key: &E,
) -> Result<CloudAttachment, CloudTransientBridgeFailure> {
    match catch_unwind(AssertUnwindSafe(|| {
        CloudAttachment::try_from_record_encrypted(&record.record_field, Some(key))
    })) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(_)) => Err(decoder_failure_at("typed_attachment")),
        Err(_) => Err(decoder_failure_at("typed_attachment_panic")),
    }
}

fn validate_participant_plaintext(value: &[u8]) -> Result<(), CloudTransientBridgeFailure> {
    if value.len() > MAX_DECOMPRESSED_FIELD_BYTES {
        return Err(CloudTransientBridgeFailure::OversizedRecord);
    }
    match catch_unwind(AssertUnwindSafe(|| {
        plist::from_bytes::<CloudParticipant>(value)
    })) {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(_)) => Err(decoder_failure_at("participant_list_element")),
        Err(_) => Err(decoder_failure_at("participant_list_element_panic")),
    }
}

/// The legacy vector implementation uses `filter_map`, which can silently
/// remove a malformed participant. Validate every encrypted element before the
/// legacy typed decoder sees the list, keeping the V2 transient path fail-closed.
fn preflight_chat_participant_list_with_decryptor<F>(
    record: &Record,
    mut decrypt: F,
) -> Result<(), CloudTransientBridgeFailure>
where
    F: FnMut(&[u8]) -> Result<Vec<u8>, CloudTransientBridgeFailure>,
{
    let Some(value) = record
        .record_field
        .iter()
        .find(|field| field_name(field) == Some("ptcpts"))
        .and_then(|field| field.value.as_ref())
    else {
        return Ok(());
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
        return Err(decoder_failure_at("participant_list_wire_shape"));
    }
    if value.list_values.len() > MAX_PARTICIPANT_COUNT {
        return Err(CloudTransientBridgeFailure::OversizedRecord);
    }
    let mut aggregate_plaintext_bytes = 0usize;
    for element in &value.list_values {
        if element.r#type != Some(FieldValueType::EncryptedBytesType as i32)
            || element.is_encrypted == Some(false)
            || !element.list_values.is_empty()
            || element.signed_value.is_some()
            || element.double_value.is_some()
            || element.date_value.is_some()
            || element.string_value.is_some()
            || element.location_value.is_some()
            || element.reference_value.is_some()
            || element.asset_value.is_some()
            || element.package_value.is_some()
        {
            return Err(decoder_failure_at("participant_list_wire_shape"));
        }
        let Some(ciphertext) = element.bytes_value.as_deref() else {
            return Err(decoder_failure_at("participant_list_wire_shape"));
        };
        let plaintext = decrypt(ciphertext)?;
        aggregate_plaintext_bytes = aggregate_plaintext_bytes
            .checked_add(plaintext.len())
            .ok_or(CloudTransientBridgeFailure::OversizedRecord)?;
        if aggregate_plaintext_bytes > MAX_PARTICIPANT_PLAINTEXT_BYTES {
            return Err(CloudTransientBridgeFailure::OversizedRecord);
        }
        validate_participant_plaintext(&plaintext)?;
    }
    Ok(())
}

fn preflight_chat_participant_list(
    record: &Record,
    key: &PCSEncryptor,
) -> Result<(), CloudTransientBridgeFailure> {
    preflight_chat_participant_list_with_decryptor(record, |ciphertext| {
        key.decrypt_data_checked(ciphertext, "ptcpts")
            .map_err(|error| map_push_failure_at(&error, "participant_list_decrypt"))
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CloudMessageUnsupportedServiceDiagnostic {
    source: &'static str,
    service_class: &'static str,
    top_level_service_class: &'static str,
    msg_proto_4_service_class: &'static str,
    message_kind: &'static str,
}

fn cloud_service_class(service: Option<&str>) -> &'static str {
    match service {
        None => "absent",
        Some("") => "empty",
        Some("iMessage") => "imessage",
        Some(value) if value.eq_ignore_ascii_case("iMessage") && value != "iMessage" => {
            "imessage_case_variant"
        }
        Some("SMS") => "sms",
        Some("RCS") => "rcs",
        Some("FaceTime") => "facetime",
        Some(_) => "other",
    }
}

fn cloud_message_kind(message: &CloudMessage) -> &'static str {
    match message.msg_proto.0.associated_message_type {
        Some(2000..=2007) | Some(3000..=3007) => "reaction",
        _ => match message.r#type {
            0..=2 => "normal",
            3..=7 => "system",
            _ => "unknown",
        },
    }
}

fn cloud_chat_style_class(chat: &CloudChat) -> &'static str {
    match chat.style {
        43 => "group",
        45 => "direct",
        _ => "unknown",
    }
}

fn cloud_message_unsupported_service_diagnostic(
    message: &CloudMessage,
) -> CloudMessageUnsupportedServiceDiagnostic {
    let top_level_service_class = cloud_service_class(Some(&message.service));
    let msg_proto_4_service_class = cloud_service_class(
        message
            .msg_proto_4
            .as_ref()
            .and_then(|proto| proto.0.service.as_deref()),
    );
    let source_and_class = if !matches!(message.service.as_str(), "iMessage" | "SMS") {
        ("top_level_svc", cloud_service_class(Some(&message.service)))
    } else if let Some(proto4) = message.msg_proto_4.as_ref().map(|proto| &proto.0) {
        (
            "msgProto4_service",
            cloud_service_class(proto4.service.as_deref()),
        )
    } else {
        ("top_level_svc", "absent")
    };

    CloudMessageUnsupportedServiceDiagnostic {
        source: source_and_class.0,
        service_class: source_and_class.1,
        top_level_service_class,
        msg_proto_4_service_class,
        message_kind: cloud_message_kind(message),
    }
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
                decoder_failure_at("native_failure_mapping")
            }
        },
    }
}

fn map_push_failure(error: &PushError) -> CloudTransientBridgeFailure {
    match error {
        PushError::PCSRecordKeyMissing
        | PushError::PCSKeyIdMismatch
        | PushError::PCSDecryptionFailed
        | PushError::NotInClique
        | PushError::ShareKeyNotFound(_)
        | PushError::MasterKeyNotFound
        | PushError::DecryptionKeyNotFound(_)
        | PushError::CloudKeyNotFound { .. }
        | PushError::NoRoutingKey => CloudTransientBridgeFailure::PcsUnavailable,
        PushError::CloudKitWarmAuthenticationRequired => {
            CloudTransientBridgeFailure::WarmAuthenticationRequired
        }
        PushError::PCSCiphertextMalformed
        | PushError::ProtobufError(_)
        | PushError::JsonError(_) => CloudTransientBridgeFailure::MalformedRecord,
        PushError::IoError(error) if error.kind() == std::io::ErrorKind::InvalidData => {
            CloudTransientBridgeFailure::MalformedRecord
        }
        PushError::UnauthorizedAccountError => CloudTransientBridgeFailure::ActiveAccountMismatch,
        PushError::RequestError(error) if error.is_timeout() || error.is_connect() => {
            CloudTransientBridgeFailure::RetryableUpstream
        }
        PushError::RequestError(error)
            if matches!(
                error.status().map(|status| status.as_u16()),
                Some(401 | 403)
            ) =>
        {
            CloudTransientBridgeFailure::ActiveAccountMismatch
        }
        PushError::RequestError(error)
            if matches!(
                error.status().map(|status| status.as_u16()),
                Some(408 | 429 | 500..=599)
            ) =>
        {
            CloudTransientBridgeFailure::RetryableUpstream
        }
        PushError::RequestError(error) if error.status().is_some() => {
            CloudTransientBridgeFailure::InvalidRequest
        }
        PushError::CloudKitHttpError { status, .. } if matches!(*status, 401 | 403) => {
            CloudTransientBridgeFailure::ActiveAccountMismatch
        }
        PushError::CloudKitHttpError { status, .. } if matches!(*status, 408 | 429 | 500..=599) => {
            CloudTransientBridgeFailure::RetryableUpstream
        }
        PushError::CloudKitHttpError { status, .. } if (400..500).contains(status) => {
            CloudTransientBridgeFailure::InvalidRequest
        }
        PushError::CloudKitError(result) => match classify_cloudkit_failure(result) {
            CloudKitFailureClass::Throttled | CloudKitFailureClass::TransientServer => {
                CloudTransientBridgeFailure::RetryableUpstream
            }
            CloudKitFailureClass::Authentication => {
                CloudTransientBridgeFailure::ActiveAccountMismatch
            }
            CloudKitFailureClass::Conflict => CloudTransientBridgeFailure::ScopeMismatch,
            CloudKitFailureClass::ResetRequired | CloudKitFailureClass::Permanent => {
                CloudTransientBridgeFailure::InvalidRequest
            }
            CloudKitFailureClass::Unknown => CloudTransientBridgeFailure::DecoderFailure,
        },
        PushError::CloudKitChangeTokenExpired => CloudTransientBridgeFailure::InvalidRequest,
        PushError::CloudKitProtocolError(_)
        | PushError::ResourceTimeout
        | PushError::ResourceGenTimeout
        | PushError::ResourceStalled
        | PushError::NotConnected
        | PushError::TooManyRequests => CloudTransientBridgeFailure::RetryableUpstream,
        PushError::IoError(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::TimedOut
                    | std::io::ErrorKind::Interrupted
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::NotConnected
                    | std::io::ErrorKind::NetworkDown
                    | std::io::ErrorKind::NetworkUnreachable
                    | std::io::ErrorKind::HostUnreachable
            ) =>
        {
            CloudTransientBridgeFailure::RetryableUpstream
        }
        // The resource wrapper is authoritative about retryability. Its inner
        // error explains why generation failed, but must not override the
        // producer's explicit backoff decision.
        PushError::ResourceFailure(failure) if failure.retry_wait.is_some() => {
            CloudTransientBridgeFailure::RetryableUpstream
        }
        // A missing retry wait is rustpush's permanent-resource marker. It is
        // the production wrapper around DoNotRetry and must remain terminal.
        PushError::ResourceFailure(_) => CloudTransientBridgeFailure::InvalidRequest,
        // There is no exported generic terminal category. InvalidRequest is
        // deliberately mapped by Dart into the terminal malformed-record lane,
        // preserving this native no-retry boundary without exposing details.
        PushError::DoNotRetry(_) => CloudTransientBridgeFailure::InvalidRequest,
        PushError::BatchError(inner) => map_push_failure(inner),
        _ => CloudTransientBridgeFailure::DecoderFailure,
    }
}

fn safe_failure_class(failure: CloudTransientBridgeFailure) -> &'static str {
    match failure {
        CloudTransientBridgeFailure::PcsUnavailable => "pcs_unavailable",
        CloudTransientBridgeFailure::RetryableUpstream => "retryable_upstream",
        CloudTransientBridgeFailure::MalformedRecord => "malformed_record",
        CloudTransientBridgeFailure::WarmAuthenticationRequired => "warm_authentication_required",
        CloudTransientBridgeFailure::InvalidRequest => "invalid_request",
        CloudTransientBridgeFailure::ActiveAccountMismatch => "active_account_mismatch",
        CloudTransientBridgeFailure::ScopeMismatch => "scope_mismatch",
        CloudTransientBridgeFailure::GenerationMismatch => "generation_mismatch",
        CloudTransientBridgeFailure::StoreIdentityMismatch => "store_identity_mismatch",
        CloudTransientBridgeFailure::ProtectedReferenceMismatch => "protected_reference_mismatch",
        CloudTransientBridgeFailure::OversizedRecord => "oversized_record",
        CloudTransientBridgeFailure::DecoderFailure => "decoder_failure",
    }
}

fn map_push_failure_at(error: &PushError, stage: &'static str) -> CloudTransientBridgeFailure {
    let failure = map_push_failure(error);
    if failure == CloudTransientBridgeFailure::DecoderFailure {
        decoder_failure_at(stage)
    } else {
        warn!(
            "CloudKit V2 transient failure class={} stage={stage}",
            safe_failure_class(failure)
        );
        failure
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

pub(crate) fn bind_envelope(
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
        || !record_type_matches_stream(envelope.stream(), envelope.record_type())
        || !valid_upsert_change_type(envelope.change_type())
    {
        return Err(CloudTransientBridgeFailure::MalformedRecord);
    }
    Ok(())
}

fn valid_upsert_change_type(change_type: Option<i32>) -> bool {
    matches!(change_type, None | Some(1 | 2))
}

fn valid_tombstone_change_type(change_type: Option<i32>) -> bool {
    matches!(change_type, None | Some(3))
}

fn record_type_matches_stream(stream: CloudNativeStream, record_type: Option<&str>) -> bool {
    record_type == Some(expected_record_type(stream))
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
        || !record_type_matches_stream(envelope.stream(), record_type)
        || change.r#type != envelope.change_type()
        || change.record.is_some()
        || !valid_tombstone_change_type(envelope.change_type())
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
            for value in [
                payload.guid(),
                payload.group_id(),
                payload.original_group_id(),
                payload.chat_identifier(),
            ] {
                let expected_alias_hash = hasher.canonical_alias_key_hash(
                    CloudCanonicalAliasKind::ChatServiceIdentifier,
                    value,
                )?;
                if !mutation.envelope().aliases().iter().any(|alias| {
                    alias.kind() == CloudCanonicalAliasKind::ChatServiceIdentifier
                        && alias.key_hash() == &expected_alias_hash
                }) {
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
    cloud_sync_decode_transient_record_with_pcs_access(
        cloud_messages_client,
        request,
        CloudTransientPcsAccess::LookupOnly,
        None,
    )
    .await
}

/// Decodes only with a Messages container and exact PCS zone configuration
/// that are already present in memory. This path performs no CloudKit zone
/// fetch, keychain synchronization, or local PCS-cache update.
pub(crate) async fn cloud_sync_decode_transient_record_cached_only(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    read_authentication_permit: &CloudKitReadAuthenticationPermit<'_>,
    request: CloudTransientDecodeRequest,
) -> CloudTransientDecodeOutcome {
    cloud_sync_decode_transient_record_with_pcs_access(
        cloud_messages_client,
        request,
        CloudTransientPcsAccess::CachedOnly,
        Some(read_authentication_permit),
    )
    .await
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloudTransientPcsAccess {
    LookupOnly,
    CachedOnly,
}

async fn cloud_sync_decode_transient_record_with_pcs_access(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    request: CloudTransientDecodeRequest,
    pcs_access: CloudTransientPcsAccess,
    read_authentication_permit: Option<&CloudKitReadAuthenticationPermit<'_>>,
) -> CloudTransientDecodeOutcome {
    let Some(storage_directory) = request.storage_directory.to_str().map(str::to_owned) else {
        return CloudTransientDecodeOutcome::Failure(CloudTransientBridgeFailure::InvalidRequest);
    };
    let actual_store_identity =
        match cloud_sync_protector::protected_store_identity(storage_directory.clone()) {
            Ok(value) => value,
            Err(_) => {
                return CloudTransientDecodeOutcome::Failure(decoder_failure_at(
                    "protected_store_identity",
                ))
            }
        };
    if actual_store_identity != request.expected_protected_store_identity {
        return CloudTransientDecodeOutcome::Failure(
            CloudTransientBridgeFailure::StoreIdentityMismatch,
        );
    }
    let raw_account_identifier = match cloud_messages_client
        .validated_native_account_identifier()
        .await
    {
        Ok(value) => value,
        Err(_) => {
            return CloudTransientDecodeOutcome::Failure(
                CloudTransientBridgeFailure::ActiveAccountMismatch,
            )
        }
    };
    let actual_account_fingerprint = match cloud_sync_protector::fingerprint_account(
        storage_directory.clone(),
        raw_account_identifier,
    ) {
        Ok(value) => value,
        Err(_) => {
            return CloudTransientDecodeOutcome::Failure(decoder_failure_at("account_fingerprint"))
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
            return CloudTransientDecodeOutcome::Failure(decoder_failure_at(
                "semantic_identifier_hasher",
            ))
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
        if request.stream == CloudNativeStream::Chats {
            let code = match envelope.kind() {
                CloudNativeRawEnvelopeKind::UnsupportedRecordType => "unsupported_record_type",
                CloudNativeRawEnvelopeKind::MalformedMetadata => "malformed_metadata",
                _ => unreachable!("matched chat envelope kind"),
            };
            warn!("CloudKit V2 transient chat diagnostic stage=envelope code={code}");
        }
        return CloudTransientDecodeOutcome::Quarantined(
            CloudCanonicalQuarantineReason::MalformedRecord,
        );
    }
    let Some(raw) = envelope.raw() else {
        return CloudTransientDecodeOutcome::Failure(missing_raw_failure(envelope.raw_length()));
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

    let mut record =
        match Record::decode(raw).map_err(|_| CloudTransientBridgeFailure::MalformedRecord) {
            Ok(value) => value,
            Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
        };
    if let Err(failure) = validate_upsert_record(&envelope, &record) {
        return CloudTransientDecodeOutcome::Failure(failure);
    }
    let mut presence = match CloudRawRecordPresence::extract(&record) {
        Ok(value) => value,
        Err(reason) => {
            if request.stream == CloudNativeStream::Chats {
                warn!(
                    "CloudKit V2 transient chat diagnostic stage=raw_presence code={}",
                    reason.diagnostic_code(),
                );
            }
            return CloudTransientDecodeOutcome::Quarantined(
                CloudCanonicalQuarantineReason::MalformedRecord,
            );
        }
    };
    let container_result = match pcs_access {
        CloudTransientPcsAccess::LookupOnly => {
            cloud_messages_client.get_container_lookup_only().await
        }
        CloudTransientPcsAccess::CachedOnly => {
            let Some(permit) = read_authentication_permit else {
                return CloudTransientDecodeOutcome::Failure(
                    CloudTransientBridgeFailure::InvalidRequest,
                );
            };
            cloud_messages_client
                .get_cached_container_for_read_authentication(permit)
                .await
        }
    };
    let container = match container_result {
        Ok(value) => value,
        Err(error) => {
            return CloudTransientDecodeOutcome::Failure(map_push_failure_at(
                &error,
                "warm_container_preflight",
            ));
        }
    };
    let zone = container.private_zone(request.stream.zone().to_owned());
    let zone_key_result = match pcs_access {
        CloudTransientPcsAccess::LookupOnly => {
            container
                .get_zone_encryption_config_lookup_only(
                    &zone,
                    &cloud_messages_client.keychain,
                    &MESSAGES_SERVICE,
                )
                .await
        }
        CloudTransientPcsAccess::CachedOnly => {
            container
                .get_cached_zone_encryption_config_exact(&zone)
                .await
        }
    };
    let zone_key = match zone_key_result {
        Ok(value) => value,
        Err(error) => {
            return CloudTransientDecodeOutcome::Failure(map_push_failure_at(
                &error,
                "zone_encryption_config",
            ));
        }
    };
    let record_key =
        match catch_unwind(AssertUnwindSafe(|| pcs_keys_for_record(&record, &zone_key))) {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => {
                return CloudTransientDecodeOutcome::Failure(map_push_failure_at(
                    &error,
                    "record_key_lookup",
                ));
            }
            Err(_) => {
                return CloudTransientDecodeOutcome::Failure(decoder_failure_at("record_key_panic"))
            }
        };
    if let Err(failure) = preflight_record_ciphertext_keys(&record, &record_key) {
        return CloudTransientDecodeOutcome::Failure(failure);
    }

    let converted = match request.stream {
        CloudNativeStream::Chats => {
            if let Err(failure) = preflight_gzip_fields(
                &mut record,
                &record_key,
                &presence,
                &[GzipFieldSpec::optional(
                    "proto001",
                    "chat_proto",
                    decode_chat_proto,
                )],
            ) {
                warn!("CloudKit V2 transient decoder stage=chat_gzip_preflight");
                return CloudTransientDecodeOutcome::Failure(failure);
            }
            if let Err(failure) = normalize_optional_empty_list_fields(
                &mut record,
                &presence,
                &["prop", "ptcpts", "name", "proto001", "gpid", "gp"],
            ) {
                return CloudTransientDecodeOutcome::Failure(failure);
            }
            if let Err(failure) = preflight_chat_participant_list(&record, &record_key) {
                return CloudTransientDecodeOutcome::Failure(failure);
            }
            match encrypted_field_bytes(&record, &record_key, "prop") {
                Ok(Some(decrypted)) => {
                    if let Err(reason) =
                        presence.capture_decrypted_plist_dictionary("prop", &decrypted)
                    {
                        warn!(
                            "CloudKit V2 transient chat diagnostic stage=prop_presence code={}",
                            reason.diagnostic_code(),
                        );
                        return CloudTransientDecodeOutcome::Quarantined(
                            CloudCanonicalQuarantineReason::MalformedRecord,
                        );
                    }
                }
                Ok(None) => {}
                Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
            }
            let strict_record_key = StrictCloudKitV2Decryptor { inner: &record_key };
            let chat = match decode_cloud_chat_record(&record, &strict_record_key) {
                Ok(value) => value,
                Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
            };
            let (converted, diagnostic) = convert_chat_with_diagnostic(&context, &presence, &chat);
            if let Some(code) = diagnostic {
                warn!(
                    "CloudKit V2 transient chat diagnostic stage=conversion code={} outcome={converted:?} service_class={} chat_style={}",
                    code.as_str(),
                    cloud_service_class(Some(&chat.service_name)),
                    cloud_chat_style_class(&chat),
                );
            }
            converted
        }
        CloudNativeStream::Messages => {
            if let Err(failure) = preflight_gzip_fields(
                &mut record,
                &record_key,
                &presence,
                &[
                    GzipFieldSpec::required("msgProto", "message_proto", decode_message_proto),
                    GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
                    GzipFieldSpec::optional("msgProto3", "message_proto_3", decode_message_proto_3),
                    GzipFieldSpec::optional("msgProto4", "message_proto_4", decode_message_proto_4),
                ],
            ) {
                warn!("CloudKit V2 transient decoder stage=message_gzip_preflight");
                return CloudTransientDecodeOutcome::Failure(failure);
            }
            if let Err(failure) = normalize_optional_empty_list_fields(
                &mut record,
                &presence,
                &["msgProto2", "msgProto3", "msgProto4"],
            ) {
                return CloudTransientDecodeOutcome::Failure(failure);
            }
            let strict_record_key = StrictCloudKitV2Decryptor { inner: &record_key };
            let message = match decode_cloud_message_record(&record, &strict_record_key) {
                Ok(value) => value,
                Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
            };
            let converted = convert_message(&context, &presence, &message);
            if matches!(
                &converted,
                CloudCanonicalConversionOutcome::Quarantined(
                    CloudCanonicalQuarantineReason::UnsupportedService
                )
            ) {
                let diagnostic = cloud_message_unsupported_service_diagnostic(&message);
                warn!(
                    "CloudKit V2 transient message unsupported_service source={} service_class={} top_level_service_class={} msg_proto_4_service_class={} message_kind={}",
                    diagnostic.source,
                    diagnostic.service_class,
                    diagnostic.top_level_service_class,
                    diagnostic.msg_proto_4_service_class,
                    diagnostic.message_kind,
                );
            }
            converted
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
            let strict_record_key = StrictCloudKitV2Decryptor { inner: &record_key };
            let attachment = match decode_cloud_attachment_record(&record, &strict_record_key) {
                Ok(value) => value,
                Err(failure) => return CloudTransientDecodeOutcome::Failure(failure),
            };
            convert_attachment(&context, &presence, &attachment.cm.0)
        }
        CloudNativeStream::MessageUpdate
        | CloudNativeStream::RecoverableMessageDelete
        | CloudNativeStream::ScheduledMessage
        | CloudNativeStream::Chat1 => {
            return CloudTransientDecodeOutcome::Failure(decoder_failure_at("unsupported_stream"));
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
    use rustpush::cloud_messages::{
        cloudmessagesp::{MessageProto, MessageProto4},
        GZipWrapper,
    };
    use rustpush::CloudKitProtocolError;

    fn digest(character: char) -> String {
        character.to_string().repeat(43)
    }

    #[test]
    fn private_change_types_match_create_update_and_delete_shapes() {
        assert!(valid_upsert_change_type(Some(1)));
        assert!(valid_upsert_change_type(Some(2)));
        assert!(valid_upsert_change_type(None));
        assert!(!valid_upsert_change_type(Some(3)));

        assert!(valid_tombstone_change_type(Some(3)));
        assert!(valid_tombstone_change_type(None));
        assert!(!valid_tombstone_change_type(Some(1)));
        assert!(!valid_tombstone_change_type(Some(2)));
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
            (CloudCanonicalAliasKind::ChatServiceIdentifier, "group-id"),
            (CloudCanonicalAliasKind::ChatServiceIdentifier, "chat-guid"),
            (
                CloudCanonicalAliasKind::ChatServiceIdentifier,
                "original-group-id",
            ),
            (
                CloudCanonicalAliasKind::ChatServiceIdentifier,
                "iMessage;-;+15555550100",
            ),
        ]
        .into_iter()
        .map(|(kind, value)| {
            let key_hash = if tamper_service_alias
                && kind == CloudCanonicalAliasKind::ChatServiceIdentifier
                && value == "iMessage;-;+15555550100"
            {
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

    fn gzip_test_record(name: &str, field_type: i32, bytes_value: Option<Vec<u8>>) -> Record {
        use rustpush::cloudkit_proto::record::field;

        Record {
            record_field: vec![Field {
                identifier: Some(field::Identifier {
                    name: Some(name.to_owned()),
                }),
                value: Some(field::Value {
                    r#type: Some(field_type),
                    bytes_value,
                    ..Default::default()
                }),
            }],
            ..Default::default()
        }
    }

    #[test]
    fn encrypted_bytes_wire_shape_requires_type_and_compatible_marker() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let valid = Value {
            r#type: Some(Type::EncryptedBytesType as i32),
            bytes_value: Some(vec![1]),
            ..Default::default()
        };
        assert_eq!(validate_encrypted_bytes_value(&valid), Ok(()));

        let explicitly_encrypted = Value {
            is_encrypted: Some(true),
            ..valid.clone()
        };
        assert_eq!(validate_encrypted_bytes_value(&explicitly_encrypted), Ok(()));

        let wrong_type = Value {
            r#type: Some(Type::BytesType as i32),
            ..valid.clone()
        };
        assert_eq!(
            validate_encrypted_bytes_value(&wrong_type),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );

        let contradictory_marker = Value {
            is_encrypted: Some(false),
            ..valid
        };
        assert_eq!(
            validate_encrypted_bytes_value(&contradictory_marker),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );

        let record = gzip_test_record("cm", Type::BytesType as i32, Some(vec![1]));
        let pcs = PCSEncryptor {
            keys: Vec::new(),
            record_id: Default::default(),
        };
        assert_eq!(
            encrypted_field_bytes(&record, &pcs, "cm"),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );
    }

    #[test]
    fn gzip_preflight_preserves_empty_list_exception_but_rejects_invalid_wire_markers() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let mut compatible = gzip_test_record(
            "msgProto2",
            Type::EncryptedBytesType as i32,
            Some(vec![1, 2, 3]),
        );
        compatible.record_field[0].value.as_mut().unwrap().is_encrypted = Some(true);
        let presence = CloudRawRecordPresence::extract(&compatible).unwrap();
        assert_eq!(
            gzip_field_requires_preflight(
                &compatible,
                &presence,
                GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            ),
            Ok(true)
        );

        compatible.record_field[0].value.as_mut().unwrap().is_encrypted = Some(false);
        let presence = CloudRawRecordPresence::extract(&compatible).unwrap();
        assert_eq!(
            gzip_field_requires_preflight(
                &compatible,
                &presence,
                GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            ),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );

        let empty_list = gzip_test_record("msgProto2", Type::EmptyList as i32, None);
        let presence = CloudRawRecordPresence::extract(&empty_list).unwrap();
        assert_eq!(
            gzip_field_requires_preflight(
                &empty_list,
                &presence,
                GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            ),
            Ok(false)
        );
    }

    #[test]
    fn only_optional_zero_length_gzip_plaintext_is_normalized_away() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let mut optional = gzip_test_record(
            "msgProto2",
            Type::EncryptedBytesType as i32,
            Some(Vec::new()),
        );
        assert!(normalize_optional_empty_gzip_field(
            &mut optional,
            GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            &[],
        ));
        assert!(optional.record_field.is_empty());

        let mut required = gzip_test_record(
            "msgProto",
            Type::EncryptedBytesType as i32,
            Some(Vec::new()),
        );
        assert!(!normalize_optional_empty_gzip_field(
            &mut required,
            GzipFieldSpec::required("msgProto", "message_proto", decode_message_proto),
            &[],
        ));
        assert_eq!(required.record_field.len(), 1);

        let mut non_empty =
            gzip_test_record("msgProto2", Type::EncryptedBytesType as i32, Some(vec![1]));
        assert!(!normalize_optional_empty_gzip_field(
            &mut non_empty,
            GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            &[1],
        ));
        assert_eq!(non_empty.record_field.len(), 1);
    }

    #[test]
    fn non_gzip_header_diagnostics_are_bounded_categories() {
        assert_eq!(non_gzip_header_stage(&[]), "header_empty");
        assert_eq!(non_gzip_header_stage(&[0x08]), "header_single_byte");
        assert_eq!(non_gzip_header_stage(&[0x78, 0x9c]), "header_zlib");
        assert_eq!(non_gzip_header_stage(b"not-gzip"), "header_non_gzip");
    }

    #[test]
    fn optional_empty_list_skips_gzip_preflight_but_required_empty_list_is_rejected() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let record = gzip_test_record("msgProto", Type::EmptyList as i32, None);
        let presence = CloudRawRecordPresence::extract(&record).unwrap();

        assert_eq!(
            gzip_field_requires_preflight(
                &record,
                &presence,
                GzipFieldSpec::optional("msgProto", "message_proto", decode_message_proto)
            ),
            Ok(false)
        );
        assert_eq!(
            gzip_field_requires_preflight(
                &record,
                &presence,
                GzipFieldSpec::required("msgProto", "message_proto", decode_message_proto)
            ),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );
    }

    #[test]
    fn missing_required_gzip_field_is_rejected() {
        let record = Record::default();
        let presence = CloudRawRecordPresence::extract(&record).unwrap();

        assert_eq!(
            gzip_field_requires_preflight(
                &record,
                &presence,
                GzipFieldSpec::required("msgProto", "message_proto", decode_message_proto)
            ),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );
        assert_eq!(
            gzip_field_requires_preflight(
                &record,
                &presence,
                GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2)
            ),
            Ok(false)
        );
    }

    #[test]
    fn optional_empty_list_with_payload_remains_malformed() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let record = gzip_test_record("msgProto2", Type::EmptyList as i32, Some(vec![1, 2, 3]));
        let presence = CloudRawRecordPresence::extract(&record).unwrap();

        assert_eq!(
            gzip_field_requires_preflight(
                &record,
                &presence,
                GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            ),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );
    }

    #[test]
    fn optional_non_empty_list_without_ciphertext_remains_malformed() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let record = gzip_test_record("msgProto2", Type::EncryptedBytesType as i32, None);
        let presence = CloudRawRecordPresence::extract(&record).unwrap();

        assert_eq!(
            gzip_field_requires_preflight(
                &record,
                &presence,
                GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            ),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );
    }

    #[test]
    fn optional_present_without_value_remains_malformed() {
        use rustpush::cloudkit_proto::record::field;

        let record = Record {
            record_field: vec![Field {
                identifier: Some(field::Identifier {
                    name: Some("msgProto2".to_owned()),
                }),
                value: None,
            }],
            ..Default::default()
        };
        let presence = CloudRawRecordPresence::extract(&record).unwrap();

        assert_eq!(
            gzip_field_requires_preflight(
                &record,
                &presence,
                GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            ),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );
    }

    #[test]
    fn optional_ciphertext_still_requires_bounded_gzip_preflight() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let record = gzip_test_record(
            "msgProto2",
            Type::EncryptedBytesType as i32,
            Some(vec![1, 2, 3]),
        );
        let presence = CloudRawRecordPresence::extract(&record).unwrap();

        assert_eq!(
            gzip_field_requires_preflight(
                &record,
                &presence,
                GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            ),
            Ok(true)
        );
    }

    #[test]
    fn optional_empty_list_normalization_is_schema_bound_and_payload_free() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let mut valid = gzip_test_record("name", Type::EmptyList as i32, None);
        let valid_presence = CloudRawRecordPresence::extract(&valid).unwrap();
        assert!(
            normalize_optional_empty_list_fields(&mut valid, &valid_presence, &["name"]).is_ok()
        );
        assert!(valid.record_field.is_empty());

        let mut malformed = gzip_test_record("name", Type::EmptyList as i32, Some(vec![1, 2, 3]));
        let malformed_presence = CloudRawRecordPresence::extract(&malformed).unwrap();
        assert_eq!(
            normalize_optional_empty_list_fields(&mut malformed, &malformed_presence, &["name"]),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );
    }

    #[test]
    fn bounded_gzip_rejects_oversized_output() {
        use flate2::{write::GzEncoder, Compression};
        use std::io::Write;

        let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
        encoder
            .write_all(&vec![0; MAX_DECOMPRESSED_FIELD_BYTES + 1])
            .unwrap();
        let compressed = encoder.finish().unwrap();

        assert_eq!(
            bounded_gunzip(&compressed).unwrap_err(),
            CloudTransientBridgeFailure::OversizedRecord
        );
    }

    #[test]
    fn bounded_gzip_rejects_trailing_bytes_and_concatenated_members() {
        use flate2::{write::GzEncoder, Compression};
        use std::io::Write;

        fn gzip(value: &[u8]) -> Vec<u8> {
            let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
            encoder.write_all(value).unwrap();
            encoder.finish().unwrap()
        }

        let first = gzip(b"first");
        let mut trailing = first.clone();
        trailing.extend_from_slice(b"trailing");
        assert_eq!(
            bounded_gunzip(&trailing),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );

        let mut concatenated = first;
        concatenated.extend_from_slice(&gzip(b"second"));
        assert_eq!(
            bounded_gunzip(&concatenated),
            Err(CloudTransientBridgeFailure::MalformedRecord)
        );
    }

    #[derive(Default)]
    struct IdentityEncryptor;

    impl CloudKitEncryptor for IdentityEncryptor {
        fn encrypt_data(&self, data: &[u8], _: &str) -> Vec<u8> {
            data.to_vec()
        }

        fn decrypt_data(&self, data: &[u8], _: &str) -> Vec<u8> {
            data.to_vec()
        }
    }

    #[test]
    fn v2_nested_protobuf_decoder_rejects_malformed_bytes_without_defaulting() {
        let spec = GzipFieldSpec::required("msgProto", "message_proto", decode_message_proto);

        assert_eq!(
            validate_nested_protobuf(&[0x80], spec),
            Err(CloudTransientBridgeFailure::DecoderFailure)
        );
        assert!(validate_nested_protobuf(&MessageProto::default().encode_to_vec(), spec).is_ok());
    }

    #[test]
    fn v2_nested_protobuf_decoder_covers_every_gzip_field() {
        for spec in [
            GzipFieldSpec::optional("proto001", "chat_proto", decode_chat_proto),
            GzipFieldSpec::required("msgProto", "message_proto", decode_message_proto),
            GzipFieldSpec::optional("msgProto2", "message_proto_2", decode_message_proto_2),
            GzipFieldSpec::optional("msgProto3", "message_proto_3", decode_message_proto_3),
            GzipFieldSpec::optional("msgProto4", "message_proto_4", decode_message_proto_4),
        ] {
            assert!(validate_nested_protobuf(&[], spec).is_ok());
            assert_eq!(
                validate_nested_protobuf(&[0x80], spec),
                Err(CloudTransientBridgeFailure::DecoderFailure)
            );
        }
    }

    #[test]
    fn v2_typed_message_decoder_returns_error_instead_of_legacy_default() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let record = gzip_test_record(
            "msgProto",
            Type::EncryptedBytesType as i32,
            Some(vec![0x80]),
        );

        assert!(matches!(
            decode_cloud_message_record(&record, &IdentityEncryptor),
            Err(CloudTransientBridgeFailure::DecoderFailure)
        ));
    }

    #[test]
    fn strict_v2_decryptor_rejects_pcs_failure_without_defaulting() {
        use rustpush::cloudkit_proto::record::field::value::Type;

        let record = gzip_test_record("guid", Type::EncryptedBytesType as i32, Some(vec![1, 2, 3]));
        let pcs = PCSEncryptor {
            keys: Vec::new(),
            record_id: Default::default(),
        };
        let strict = StrictCloudKitV2Decryptor { inner: &pcs };

        assert!(matches!(
            decode_cloud_message_record(&record, &strict),
            Err(CloudTransientBridgeFailure::DecoderFailure)
        ));
    }

    #[test]
    fn malformed_participant_list_element_is_fail_closed() {
        use rustpush::cloudkit_proto::record::field;

        let record = Record {
            record_field: vec![Field {
                identifier: Some(field::Identifier {
                    name: Some("ptcpts".to_owned()),
                }),
                value: Some(field::Value {
                    list_values: vec![field::Value {
                        bytes_value: Some(b"not-a-binary-plist".to_vec()),
                        ..Default::default()
                    }],
                    ..Default::default()
                }),
            }],
            ..Default::default()
        };

        assert_eq!(
            preflight_chat_participant_list_with_decryptor(&record, |value| Ok(value.to_vec())),
            Err(CloudTransientBridgeFailure::DecoderFailure)
        );
    }

    fn participant_list_record(value: Value) -> Record {
        use rustpush::cloudkit_proto::record::field;

        Record {
            record_field: vec![Field {
                identifier: Some(field::Identifier {
                    name: Some("ptcpts".to_owned()),
                }),
                value: Some(value),
            }],
            ..Default::default()
        }
    }

    fn participant_plaintext(uri_length: usize) -> Vec<u8> {
        let participant = CloudParticipant {
            uri: "x".repeat(uri_length),
        };
        let mut bytes = Vec::new();
        plist::to_writer_binary(&mut bytes, &participant).unwrap();
        bytes
    }

    fn participant_element(ciphertext: Vec<u8>) -> Value {
        Value {
            r#type: Some(FieldValueType::EncryptedBytesType as i32),
            bytes_value: Some(ciphertext),
            ..Default::default()
        }
    }

    #[test]
    fn participant_list_requires_encrypted_wire_shapes_and_accepts_absent_markers() {
        let plaintext = participant_plaintext(8);
        let valid = participant_list_record(Value {
            r#type: Some(FieldValueType::EncryptedBytesListType as i32),
            list_values: vec![participant_element(vec![1])],
            ..Default::default()
        });
        assert_eq!(
            preflight_chat_participant_list_with_decryptor(&valid, |_| Ok(plaintext.clone())),
            Ok(())
        );

        let observed_markers = participant_list_record(Value {
            r#type: Some(FieldValueType::EncryptedBytesListType as i32),
            is_encrypted: Some(false),
            list_values: vec![Value {
                is_encrypted: Some(true),
                ..participant_element(vec![1])
            }],
            ..Default::default()
        });
        assert_eq!(
            preflight_chat_participant_list_with_decryptor(&observed_markers, |_| {
                Ok(plaintext.clone())
            }),
            Ok(())
        );

        let invalid_outer_type = participant_list_record(Value {
            r#type: Some(FieldValueType::BytesListType as i32),
            list_values: vec![participant_element(vec![1])],
            ..Default::default()
        });
        assert_eq!(
            preflight_chat_participant_list_with_decryptor(&invalid_outer_type, |_| Ok(Vec::new())),
            Err(CloudTransientBridgeFailure::DecoderFailure)
        );

        let invalid_outer_marker = participant_list_record(Value {
            r#type: Some(FieldValueType::EncryptedBytesListType as i32),
            is_encrypted: Some(true),
            list_values: vec![participant_element(vec![1])],
            ..Default::default()
        });
        assert_eq!(
            preflight_chat_participant_list_with_decryptor(&invalid_outer_marker, |_| Ok(Vec::new())),
            Err(CloudTransientBridgeFailure::DecoderFailure)
        );

        let invalid_element_type = participant_list_record(Value {
            r#type: Some(FieldValueType::EncryptedBytesListType as i32),
            list_values: vec![Value {
                r#type: Some(FieldValueType::BytesType as i32),
                bytes_value: Some(vec![1]),
                ..Default::default()
            }],
            ..Default::default()
        });
        assert_eq!(
            preflight_chat_participant_list_with_decryptor(&invalid_element_type, |_| Ok(Vec::new())),
            Err(CloudTransientBridgeFailure::DecoderFailure)
        );

        let invalid_element_marker = participant_list_record(Value {
            r#type: Some(FieldValueType::EncryptedBytesListType as i32),
            list_values: vec![Value {
                is_encrypted: Some(false),
                ..participant_element(vec![1])
            }],
            ..Default::default()
        });
        assert_eq!(
            preflight_chat_participant_list_with_decryptor(&invalid_element_marker, |_| Ok(Vec::new())),
            Err(CloudTransientBridgeFailure::DecoderFailure)
        );
    }

    #[test]
    fn encrypted_value_key_preflight_rejects_excessive_nesting() {
        let pcs = PCSEncryptor {
            keys: Vec::new(),
            record_id: Default::default(),
        };
        let mut value = Value::default();
        for _ in 0..=MAX_ENCRYPTED_VALUE_NESTING_DEPTH {
            value = Value {
                list_values: vec![value],
                ..Default::default()
            };
        }
        assert_eq!(
            preflight_encrypted_value_keys(&pcs, &value),
            Err(CloudTransientBridgeFailure::OversizedRecord)
        );
    }

    #[test]
    fn participant_list_rejects_excessive_count_before_decryption() {
        let record = participant_list_record(Value {
            r#type: Some(FieldValueType::EncryptedBytesListType as i32),
            list_values: vec![participant_element(vec![1]); MAX_PARTICIPANT_COUNT + 1],
            ..Default::default()
        });
        assert_eq!(
            preflight_chat_participant_list_with_decryptor(&record, |_| panic!("must not decrypt")),
            Err(CloudTransientBridgeFailure::OversizedRecord)
        );
    }

    #[test]
    fn participant_list_rejects_excessive_aggregate_plaintext() {
        let plaintext = participant_plaintext(MAX_DECOMPRESSED_FIELD_BYTES - 1024);
        assert!(plaintext.len() <= MAX_DECOMPRESSED_FIELD_BYTES);
        assert!(plaintext.len() * 3 > MAX_PARTICIPANT_PLAINTEXT_BYTES);
        let record = participant_list_record(Value {
            r#type: Some(FieldValueType::EncryptedBytesListType as i32),
            list_values: vec![participant_element(vec![1]); 3],
            ..Default::default()
        });
        assert_eq!(
            preflight_chat_participant_list_with_decryptor(&record, |_| Ok(plaintext.clone())),
            Err(CloudTransientBridgeFailure::OversizedRecord)
        );
    }

    #[test]
    fn wire_shape_failures_do_not_include_field_content() {
        let secret = "private-wire-shape-content";
        let failure = validate_encrypted_bytes_value(&Value {
            r#type: Some(FieldValueType::BytesType as i32),
            bytes_value: Some(secret.as_bytes().to_vec()),
            ..Default::default()
        })
        .unwrap_err();
        assert_eq!(failure, CloudTransientBridgeFailure::MalformedRecord);
        assert!(!format!("{failure:?}").contains(secret));
    }

    #[test]
    fn malformed_nested_record_does_not_poison_independent_valid_siblings() {
        let spec = GzipFieldSpec::required("msgProto", "message_proto", decode_message_proto);
        let valid = MessageProto::default().encode_to_vec();

        assert!(validate_nested_protobuf(&valid, spec).is_ok());
        assert_eq!(
            validate_nested_protobuf(&[0x80], spec),
            Err(CloudTransientBridgeFailure::DecoderFailure)
        );
        assert!(validate_nested_protobuf(&valid, spec).is_ok());
    }

    #[test]
    fn v2_decoder_diagnostics_redact_record_content_and_identifiers() {
        let secret = "private-message-content-and-record-identifier";
        let failure = validate_participant_plaintext(secret.as_bytes()).unwrap_err();
        let rendered = format!("{failure:?}");

        assert_eq!(failure, CloudTransientBridgeFailure::DecoderFailure);
        assert!(!rendered.contains(secret));
        assert!(!rendered.contains("participant"));
    }

    fn diagnostic_message(
        message_type: i64,
        associated_message_type: Option<u32>,
        service: &str,
    ) -> CloudMessage {
        CloudMessage {
            r#type: message_type,
            msg_proto: GZipWrapper(MessageProto {
                associated_message_type,
                ..Default::default()
            }),
            service: service.to_owned(),
            ..Default::default()
        }
    }

    fn diagnostic_message_with_proto4_service(service: Option<&str>) -> CloudMessage {
        CloudMessage {
            msg_proto_4: service.map(|service| {
                GZipWrapper(MessageProto4 {
                    service: Some(service.to_owned()),
                    ..Default::default()
                })
            }),
            ..diagnostic_message(1, None, "iMessage")
        }
    }

    #[test]
    fn unsupported_service_diagnostic_classifies_fixed_source_and_service_labels() {
        assert_eq!(cloud_service_class(None), "absent");
        for (service, expected) in [
            ("", "empty"),
            ("iMessage", "imessage"),
            ("IMESSAGE", "imessage_case_variant"),
            ("SMS", "sms"),
            ("RCS", "rcs"),
            ("FaceTime", "facetime"),
            ("private-service-name", "other"),
        ] {
            assert_eq!(cloud_service_class(Some(service)), expected);
        }

        let nested_absent = CloudMessage {
            msg_proto_4: Some(GZipWrapper(MessageProto4::default())),
            ..diagnostic_message(1, None, "iMessage")
        };
        assert_eq!(
            cloud_message_unsupported_service_diagnostic(&nested_absent),
            CloudMessageUnsupportedServiceDiagnostic {
                source: "msgProto4_service",
                service_class: "absent",
                top_level_service_class: "imessage",
                msg_proto_4_service_class: "absent",
                message_kind: "normal",
            }
        );

        let top_level = diagnostic_message(1, None, "RCS");
        assert_eq!(
            cloud_message_unsupported_service_diagnostic(&top_level),
            CloudMessageUnsupportedServiceDiagnostic {
                source: "top_level_svc",
                service_class: "rcs",
                top_level_service_class: "rcs",
                msg_proto_4_service_class: "absent",
                message_kind: "normal",
            }
        );

        let nested = diagnostic_message_with_proto4_service(Some("FaceTime"));
        assert_eq!(
            cloud_message_unsupported_service_diagnostic(&nested),
            CloudMessageUnsupportedServiceDiagnostic {
                source: "msgProto4_service",
                service_class: "facetime",
                top_level_service_class: "imessage",
                msg_proto_4_service_class: "facetime",
                message_kind: "normal",
            }
        );

        let nested_imessage_for_sms = CloudMessage {
            msg_proto_4: Some(GZipWrapper(MessageProto4 {
                service: Some("iMessage".to_owned()),
                ..Default::default()
            })),
            ..diagnostic_message(1, None, "SMS")
        };
        assert_eq!(
            cloud_message_unsupported_service_diagnostic(&nested_imessage_for_sms),
            CloudMessageUnsupportedServiceDiagnostic {
                source: "msgProto4_service",
                service_class: "imessage",
                top_level_service_class: "sms",
                msg_proto_4_service_class: "imessage",
                message_kind: "normal",
            }
        );
    }

    #[test]
    fn unsupported_service_diagnostic_emits_both_service_levels_as_fixed_labels() {
        let cases = [
            ("iMessage", Some("RCS"), "imessage", "rcs"),
            ("SMS", Some("RCS"), "sms", "rcs"),
            ("RCS", None, "rcs", "absent"),
            ("iMessage", None, "imessage", "absent"),
            ("IMESSAGE", Some("rcs"), "imessage_case_variant", "other"),
            (
                "carrier-extension",
                Some("carrier-extension"),
                "other",
                "other",
            ),
        ];

        for (top_level, nested, expected_top_level, expected_nested) in cases {
            let message = CloudMessage {
                msg_proto_4: nested.map(|service| {
                    GZipWrapper(MessageProto4 {
                        service: Some(service.to_owned()),
                        ..Default::default()
                    })
                }),
                ..diagnostic_message(1, None, top_level)
            };
            let diagnostic = cloud_message_unsupported_service_diagnostic(&message);

            assert_eq!(diagnostic.top_level_service_class, expected_top_level);
            assert_eq!(diagnostic.msg_proto_4_service_class, expected_nested);
            let rendered = format!(
                "top_level_service_class={} msg_proto_4_service_class={}",
                diagnostic.top_level_service_class, diagnostic.msg_proto_4_service_class,
            );
            assert!(!rendered.contains(top_level));
            if let Some(nested) = nested {
                assert!(!rendered.contains(nested));
            }
        }
    }

    #[test]
    fn unsupported_chat_service_diagnostic_uses_fixed_labels_only() {
        for (style, expected) in [(43, "group"), (45, "direct"), (99, "unknown")] {
            let chat = CloudChat {
                style,
                service_name: "private-service-name".to_owned(),
                ..Default::default()
            };
            assert_eq!(cloud_chat_style_class(&chat), expected);
            assert_eq!(cloud_service_class(Some(&chat.service_name)), "other");
            let rendered = format!(
                "service_class={} chat_style={}",
                cloud_service_class(Some(&chat.service_name)),
                cloud_chat_style_class(&chat),
            );
            assert!(!rendered.contains("private-service-name"));
        }
    }

    #[test]
    fn unsupported_service_diagnostic_classifies_message_kind_without_identifiers() {
        for (message_type, association, expected) in [
            (1, None, "normal"),
            (0, Some(2000), "reaction"),
            (2, Some(3007), "reaction"),
            (3, None, "system"),
            (7, None, "system"),
            (8, None, "unknown"),
            (-1, None, "unknown"),
        ] {
            let message = diagnostic_message(message_type, association, "RCS");
            let diagnostic = cloud_message_unsupported_service_diagnostic(&message);
            assert_eq!(diagnostic.message_kind, expected);
            assert!(!format!("{diagnostic:?}").contains("RCS"));
            assert!(!format!("{diagnostic:?}").contains("private"));
        }
    }

    #[test]
    fn missing_raw_body_distinguishes_bounded_malformed_from_oversized() {
        assert_eq!(
            missing_raw_failure(MAX_RAW_RECORD_BYTES as u64),
            CloudTransientBridgeFailure::MalformedRecord
        );
        assert_eq!(
            missing_raw_failure(MAX_RAW_RECORD_BYTES as u64 + 1),
            CloudTransientBridgeFailure::OversizedRecord
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
    fn semantic_failure_mapping_classifies_warm_auth_as_authorization_not_pcs() {
        let warm_auth = map_push_failure(&PushError::CloudKitWarmAuthenticationRequired);
        assert_eq!(
            warm_auth,
            CloudTransientBridgeFailure::WarmAuthenticationRequired
        );
        assert_ne!(
            warm_auth,
            CloudTransientBridgeFailure::ActiveAccountMismatch
        );
        assert_ne!(warm_auth, CloudTransientBridgeFailure::PcsUnavailable);

        let rendered = format!("{warm_auth:?}");
        for sentinel in [
            "private-message-sentinel",
            "dsid-sentinel",
            "token-sentinel",
            "peer-id-sentinel",
            "key-id-sentinel",
        ] {
            assert!(!rendered.contains(sentinel));
        }
    }

    #[test]
    fn semantic_failure_mapping_classifies_zone_pcs_failures_without_exposing_details() {
        for error in [
            PushError::CloudKeyNotFound {
                zone: "private-zone".to_owned(),
                class: "private-class".to_owned(),
            },
            PushError::NoRoutingKey,
            PushError::PCSRecordKeyMissing,
        ] {
            assert_eq!(
                map_push_failure_at(&error, "zone_encryption_config"),
                CloudTransientBridgeFailure::PcsUnavailable
            );
        }
        assert_eq!(
            safe_failure_class(CloudTransientBridgeFailure::PcsUnavailable),
            "pcs_unavailable"
        );
    }

    #[test]
    fn semantic_failure_mapping_classifies_transport_failures_as_retryable() {
        for kind in [
            std::io::ErrorKind::TimedOut,
            std::io::ErrorKind::ConnectionReset,
            std::io::ErrorKind::NetworkUnreachable,
        ] {
            let error = PushError::IoError(std::io::Error::new(kind, "private transport detail"));
            assert_eq!(
                map_push_failure_at(&error, "zone_encryption_config"),
                CloudTransientBridgeFailure::RetryableUpstream
            );
        }
        for error in [
            PushError::ResourceTimeout,
            PushError::ResourceGenTimeout,
            PushError::ResourceStalled,
            PushError::NotConnected,
        ] {
            assert_eq!(
                map_push_failure_at(&error, "zone_encryption_config"),
                CloudTransientBridgeFailure::RetryableUpstream
            );
        }
    }

    #[test]
    fn semantic_failure_mapping_preserves_cloudkit_failure_classes() {
        use rustpush::cloudkit_proto::response_operation::result::error::{client, server};

        let cloudkit_server =
            |code: server::Code| {
                PushError::CloudKitError(rustpush::cloudkit_proto::response_operation::Result {
                error: Some(rustpush::cloudkit_proto::response_operation::result::Error {
                    server_error: Some(
                        rustpush::cloudkit_proto::response_operation::result::error::Server {
                            r#type: Some(code as i32),
                        },
                    ),
                    ..Default::default()
                }),
                ..Default::default()
            })
            };
        let cloudkit_client =
            |code: client::Code| {
                PushError::CloudKitError(rustpush::cloudkit_proto::response_operation::Result {
                error: Some(rustpush::cloudkit_proto::response_operation::result::Error {
                    client_error: Some(
                        rustpush::cloudkit_proto::response_operation::result::error::Client {
                            r#type: Some(code as i32),
                        },
                    ),
                    ..Default::default()
                }),
                ..Default::default()
            })
            };

        assert_eq!(
            map_push_failure(&cloudkit_server(server::Code::Overloaded)),
            CloudTransientBridgeFailure::RetryableUpstream
        );
        assert_eq!(
            map_push_failure(&cloudkit_client(client::Code::NeedsAuthentication)),
            CloudTransientBridgeFailure::ActiveAccountMismatch
        );
        assert_eq!(
            map_push_failure(&cloudkit_client(client::Code::StaleRecordUpdate)),
            CloudTransientBridgeFailure::ScopeMismatch
        );
        assert_eq!(
            map_push_failure(&cloudkit_server(server::Code::NotFound)),
            CloudTransientBridgeFailure::InvalidRequest
        );
        assert_eq!(
            map_push_failure(&PushError::CloudKitError(Default::default())),
            CloudTransientBridgeFailure::DecoderFailure
        );
    }

    #[test]
    fn semantic_failure_mapping_classifies_protocol_failures_as_malformed() {
        for error in [
            PushError::PCSCiphertextMalformed,
            PushError::ProtobufError(prost::DecodeError::new("private protobuf detail")),
            PushError::IoError(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "private protocol detail",
            )),
        ] {
            assert_eq!(
                map_push_failure_at(&error, "zone_encryption_config"),
                CloudTransientBridgeFailure::MalformedRecord
            );
        }
        assert_eq!(
            safe_failure_class(CloudTransientBridgeFailure::MalformedRecord),
            "malformed_record"
        );
    }

    #[test]
    fn semantic_failure_mapping_retries_nonprogressing_cloudkit_pages() {
        assert_eq!(
            map_push_failure_at(
                &PushError::CloudKitProtocolError(
                    CloudKitProtocolError::ContinuationTokenNoProgress,
                ),
                "zone_encryption_config",
            ),
            CloudTransientBridgeFailure::RetryableUpstream
        );
    }

    #[test]
    fn semantic_failure_mapping_preserves_explicit_no_retry_boundary() {
        assert_eq!(
            map_push_failure(&PushError::DoNotRetry(
                Box::new(PushError::ResourceTimeout,)
            )),
            CloudTransientBridgeFailure::InvalidRequest
        );
    }

    #[test]
    fn semantic_failure_mapping_honors_explicit_resource_retry_hint() {
        assert_eq!(
            map_push_failure(&PushError::ResourceFailure(rustpush::ResourceFailure {
                retry_wait: Some(5),
                error: Arc::new(PushError::PCSCiphertextMalformed),
            })),
            CloudTransientBridgeFailure::RetryableUpstream
        );
    }

    #[test]
    fn semantic_failure_mapping_preserves_permanent_resource_wrapper() {
        assert_eq!(
            map_push_failure(&PushError::ResourceFailure(rustpush::ResourceFailure {
                retry_wait: None,
                error: Arc::new(PushError::DoNotRetry(Box::new(PushError::ResourceTimeout,))),
            })),
            CloudTransientBridgeFailure::InvalidRequest
        );
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

    #[test]
    fn cloudkit_record_types_are_stream_fenced_for_upserts_and_tombstones() {
        assert!(record_type_matches_stream(
            CloudNativeStream::Chats,
            Some(CloudChat::record_type())
        ));
        assert!(record_type_matches_stream(
            CloudNativeStream::Messages,
            Some(CloudMessage::record_type())
        ));
        assert!(record_type_matches_stream(
            CloudNativeStream::Attachments,
            Some(CloudAttachment::record_type())
        ));
        assert!(!record_type_matches_stream(
            CloudNativeStream::Messages,
            Some(CloudChat::record_type())
        ));
        assert!(!record_type_matches_stream(
            CloudNativeStream::Attachments,
            Some(CloudMessage::record_type())
        ));
        assert!(!record_type_matches_stream(CloudNativeStream::Chats, None));
    }
}
