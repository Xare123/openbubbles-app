//! Retain one exact conditional message update under a committed protected lease.
//! No network, claims, IDS resend, ETag refresh, or save authority lives here.
//! The caller must prove mutation source/receipt and current account before
//! staging, then bind this immutable attempt into its journal before commit.
#![cfg_attr(not(test), allow(dead_code))]

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use prost::Message;
use rustpush::cloudkit_proto::{record::field::value::Type, Record, RecordSaveRequest};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, path::PathBuf};

use crate::cloud_sync_native_fetch::{
    cloud_sync_open_protected_message_update, cloud_sync_stage_protected_message_update,
    cloud_sync_verify_committed_lease_exact,
};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;

const MAX_RECORD_BYTES: usize = 4 * 1024 * 1024;
// Envelope base64 plus the protector's outer base64 must fit its 18 MiB file
// limit. Keep room for the authenticated context, cipher overhead and lease.
const MAX_ENVELOPE_BYTES: usize = 9 * 1024 * 1024;
const MAX_FIELDS: usize = 4096;

// Content-free exact context. Hashes must come from the native-validated
// mutation journal, not be inferred from matching message text.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct MessageUpdateBinding {
    pub(crate) logical_entity_key_hash: String,
    pub(crate) server_record_id_hash: String,
    pub(crate) predecessor_etag_hash: String,
    pub(crate) mutation_source_sha256: String,
    pub(crate) ids_receipt_binding_sha256: String,
    pub(crate) reflected_snapshot_sha256: String,
    pub(crate) auth_binding_sha256: String,
    pub(crate) writer_epoch: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    v: u32,
    binding: MessageUpdateBinding,
    predecessor_b64: String,
    request_b64: String,
}

#[derive(Clone)]
pub(crate) struct StagedMessageUpdate {
    pub(crate) protected_reference: String,
    pub(crate) lease_reference: String,
    pub(crate) payload_sha256: String,
}

// Deliberately not Debug/Serialize. Raw identifiers, ETags and payloads stay native.
pub(crate) struct OpenedMessageUpdate {
    predecessor: Record,
    request: RecordSaveRequest,
    binding: MessageUpdateBinding,
}

impl OpenedMessageUpdate {
    pub(crate) fn predecessor(&self) -> &Record {
        &self.predecessor
    }
    pub(crate) fn request(&self) -> &RecordSaveRequest {
        &self.request
    }
    pub(crate) fn binding(&self) -> &MessageUpdateBinding {
        &self.binding
    }
}

pub(crate) fn stage_message_update(
    directory: PathBuf,
    account_fingerprint: String,
    binding: MessageUpdateBinding,
    predecessor: &Record,
    request: &RecordSaveRequest,
) -> Result<StagedMessageUpdate, Failure> {
    validate_binding(&binding)?;
    validate_request(predecessor, request)?;
    let envelope = Envelope {
        v: 1,
        binding,
        predecessor_b64: URL_SAFE_NO_PAD.encode(predecessor.encode_to_vec()),
        request_b64: URL_SAFE_NO_PAD.encode(request.encode_to_vec()),
    };
    let bytes = serde_json::to_vec(&envelope).map_err(|_| Failure::MalformedMessage)?;
    if bytes.len() > MAX_ENVELOPE_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let staged = cloud_sync_stage_protected_message_update(
        directory,
        account_fingerprint,
        URL_SAFE_NO_PAD.encode(&bytes),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    Ok(StagedMessageUpdate {
        protected_reference: staged.protected_envelope_reference,
        lease_reference: staged.lease_reference,
        payload_sha256: digest(&bytes),
    })
}

pub(crate) fn open_message_update(
    directory: PathBuf,
    account_fingerprint: String,
    expected: &MessageUpdateBinding,
    stage: &StagedMessageUpdate,
) -> Result<OpenedMessageUpdate, Failure> {
    validate_binding(expected)?;
    if !is_digest(&stage.payload_sha256) {
        return Err(Failure::MalformedMessage);
    }
    cloud_sync_verify_committed_lease_exact(
        directory.clone(),
        &stage.lease_reference,
        std::slice::from_ref(&stage.protected_reference),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let encoded = cloud_sync_open_protected_message_update(
        directory,
        account_fingerprint,
        &stage.protected_reference,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let bytes = decode_bounded(&encoded, MAX_ENVELOPE_BYTES)?;
    if digest(&bytes) != stage.payload_sha256 {
        return Err(Failure::BindingMismatch);
    }
    let envelope: Envelope =
        serde_json::from_slice(&bytes).map_err(|_| Failure::MalformedMessage)?;
    if envelope.v != 1
        || serde_json::to_vec(&envelope).map_err(|_| Failure::MalformedMessage)? != bytes
    {
        return Err(Failure::MalformedMessage);
    }
    if &envelope.binding != expected {
        return Err(Failure::BindingMismatch);
    }
    let predecessor_bytes = decode_bounded(&envelope.predecessor_b64, MAX_RECORD_BYTES)?;
    let request_bytes = decode_bounded(&envelope.request_b64, MAX_RECORD_BYTES)?;
    let predecessor =
        Record::decode(predecessor_bytes.as_slice()).map_err(|_| Failure::MalformedMessage)?;
    let request = RecordSaveRequest::decode(request_bytes.as_slice())
        .map_err(|_| Failure::MalformedMessage)?;
    // The staged operation must be exactly replayable. Never silently strip
    // unknown request fields or canonicalize a changed recovered attempt.
    if predecessor.encode_to_vec() != predecessor_bytes || request.encode_to_vec() != request_bytes
    {
        return Err(Failure::MalformedMessage);
    }
    validate_request(&predecessor, &request)?;
    Ok(OpenedMessageUpdate {
        predecessor,
        request,
        binding: envelope.binding,
    })
}

fn validate_binding(binding: &MessageUpdateBinding) -> Result<(), Failure> {
    if !is_keyed_hash(&binding.logical_entity_key_hash)
        || !is_keyed_hash(&binding.server_record_id_hash)
        || !is_keyed_hash(&binding.predecessor_etag_hash)
    {
        return Err(Failure::MalformedMessage);
    }
    if [
        &binding.mutation_source_sha256,
        &binding.ids_receipt_binding_sha256,
        &binding.reflected_snapshot_sha256,
        &binding.auth_binding_sha256,
    ]
    .iter()
    .any(|value| !is_digest(value))
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}

fn is_keyed_hash(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

/// This lane may replace only encrypted msgProto and the unencrypted update
/// clock. All server-only metadata and other fields remain server-owned via
/// merge=true. It cannot express create, delete, PCS rotation or an override.
fn validate_request(previous: &Record, request: &RecordSaveRequest) -> Result<(), Failure> {
    if previous.encoded_len() > MAX_RECORD_BYTES || request.encoded_len() > MAX_RECORD_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let id = previous
        .record_identifier
        .as_ref()
        .ok_or(Failure::MalformedMessage)?;
    let zone = id
        .zone_identifier
        .as_ref()
        .ok_or(Failure::MalformedMessage)?;
    let nonblank =
        |value: Option<&str>| value.is_some_and(|s| !s.trim().is_empty() && s.len() <= 4096);
    if !nonblank(id.value.as_ref().and_then(|v| v.name.as_deref()))
        || id.value.as_ref().and_then(|v| v.r#type) != Some(1)
        || zone.value.as_ref().and_then(|v| v.name.as_deref()) != Some("messageManateeZone")
        || zone.value.as_ref().and_then(|v| v.r#type) != Some(6)
        || !nonblank(
            zone.owner_identifier
                .as_ref()
                .and_then(|v| v.name.as_deref()),
        )
        || zone.owner_identifier.as_ref().and_then(|v| v.r#type) != Some(7)
        || previous.r#type.as_ref().and_then(|v| v.name.as_deref()) != Some("MessageEncryptedV3")
        || !nonblank(previous.etag.as_deref())
        || previous.protection_info.is_some()
        || previous.pcs_key.as_ref().is_none_or(|v| v.len() != 4)
        || previous.record_field.len() > MAX_FIELDS
        || request.merge != Some(true)
        || request.save_semantics != Some(1)
        || request.etag != previous.etag
        || !request.fields_to_delete_if_exist_on_merge.is_empty()
    {
        return Err(Failure::MalformedMessage);
    }
    let record = request.record.as_ref().ok_or(Failure::MalformedMessage)?;
    let expected = Record {
        record_identifier: previous.record_identifier.clone(),
        r#type: previous.r#type.clone(),
        pcs_key: previous.pcs_key.clone(),
        record_field: record.record_field.clone(),
        ..Default::default()
    };
    if record != &expected || record.record_field.is_empty() || record.record_field.len() > 2 {
        return Err(Failure::MalformedMessage);
    }
    let mut previous_names = HashSet::new();
    for field in &previous.record_field {
        let name = field
            .identifier
            .as_ref()
            .and_then(|v| v.name.as_deref())
            .ok_or(Failure::MalformedMessage)?;
        if name.is_empty() || !previous_names.insert(name) {
            return Err(Failure::MalformedMessage);
        }
    }
    if !previous_names.contains("msgProto") {
        return Err(Failure::MalformedMessage);
    }
    let mut fields = HashSet::new();
    for field in &record.record_field {
        let name = field
            .identifier
            .as_ref()
            .and_then(|v| v.name.as_deref())
            .ok_or(Failure::MalformedMessage)?;
        let value = field.value.as_ref().ok_or(Failure::MalformedMessage)?;
        if !fields.insert(name) {
            return Err(Failure::MalformedMessage);
        }
        let mut expected_value = rustpush::cloudkit_proto::record::field::Value::default();
        match name {
            "msgProto" => {
                if value.bytes_value.as_ref().is_none_or(|b| b.is_empty()) {
                    return Err(Failure::MalformedMessage);
                }
                expected_value.r#type = Some(Type::EncryptedBytesType as i32);
                expected_value.is_encrypted = Some(true);
                expected_value.bytes_value = value.bytes_value.clone();
            }
            "utm" => {
                let time = value
                    .date_value
                    .as_ref()
                    .and_then(|d| d.time)
                    .ok_or(Failure::MalformedMessage)?;
                if !time.is_finite() || time <= 0.0 || time > MAX_UTM_TIME {
                    return Err(Failure::MalformedMessage);
                }
                expected_value.r#type = Some(Type::DateType as i32);
                expected_value.date_value = value.date_value.clone();
            }
            _ => return Err(Failure::UnsupportedMessage),
        }
        if value != &expected_value {
            return Err(Failure::MalformedMessage);
        }
    }
    if !fields.contains("msgProto") {
        return Err(Failure::MalformedMessage);
    }
    // A staged attempt must actually change the ciphertext. Saving byte-
    // identical payload bytes would be a no-op write, never a message update.
    // A missing or empty predecessor payload is malformed, never treated as
    // absent to skip this comparison.
    let before = message_bytes(previous, "msgProto").ok_or(Failure::MalformedMessage)?;
    if before.is_empty() {
        return Err(Failure::MalformedMessage);
    }
    let after = message_bytes(record, "msgProto").ok_or(Failure::MalformedMessage)?;
    if before == after {
        return Err(Failure::MalformedMessage);
    }
    // The update clock must not move backwards. A present predecessor clock
    // must be a finite in-range timestamp; a malformed stored clock is
    // rejected instead of treated as absent. Either side may omit the clock;
    // only two parseable clocks are ordered numerically. Equal clocks are
    // explicitly allowed.
    let stored_clock = validated_predecessor_clock(previous)?;
    if let (Some(before), Some(after)) = (stored_clock, update_clock(record)) {
        if after < before {
            return Err(Failure::MalformedMessage);
        }
    }
    Ok(())
}

fn message_bytes<'a>(record: &'a Record, name: &str) -> Option<&'a [u8]> {
    record
        .record_field
        .iter()
        .find(|field| {
            field
                .identifier
                .as_ref()
                .and_then(|identifier| identifier.name.as_deref())
                == Some(name)
        })?
        .value
        .as_ref()?
        .bytes_value
        .as_deref()
}

/// Accepted `utm` bound shared by the request shape check and the stored
/// predecessor check.
const MAX_UTM_TIME: f64 = 252_423_993_599.0;

/// Fail-closed numeric view of the stored predecessor `utm` clock.
/// Returns `Ok(None)` only when the predecessor omits the clock entirely.
/// A present predecessor clock must carry a finite in-range timestamp;
/// non-finite, missing, or out-of-range stored clocks are rejected instead
/// of being treated as absent.
fn validated_predecessor_clock(previous: &Record) -> Result<Option<f64>, Failure> {
    let field = previous.record_field.iter().find(|field| {
        field
            .identifier
            .as_ref()
            .and_then(|identifier| identifier.name.as_deref())
            == Some("utm")
    });
    let Some(field) = field else {
        return Ok(None);
    };
    let time = field
        .value
        .as_ref()
        .and_then(|value| value.date_value.as_ref())
        .and_then(|date| date.time);
    match time {
        Some(time) if time.is_finite() && time > 0.0 && time <= MAX_UTM_TIME => Ok(Some(time)),
        _ => Err(Failure::MalformedMessage),
    }
}

/// Best-effort numeric view of the unencrypted `utm` update clock on the
/// request side. Returns `None` when the clock is absent; a malformed
/// request clock is already rejected by the request shape check above, so
/// only absence reaches the comparison. The raw timestamp is compared
/// directly so fractional values cannot slip backwards inside one integer
/// second through truncation.
fn update_clock(record: &Record) -> Option<f64> {
    let time = record
        .record_field
        .iter()
        .find(|field| {
            field
                .identifier
                .as_ref()
                .and_then(|identifier| identifier.name.as_deref())
                == Some("utm")
        })?
        .value
        .as_ref()?
        .date_value
        .as_ref()?
        .time?;
    if !time.is_finite() {
        return None;
    }
    Some(time)
}

fn is_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
}
fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn decode_bounded(encoded: &str, max: usize) -> Result<Vec<u8>, Failure> {
    if encoded.is_empty() || encoded.len() > max.div_ceil(3) * 4 {
        return Err(Failure::OversizedMessage);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| Failure::MalformedMessage)?;
    if bytes.is_empty() || bytes.len() > max {
        return Err(Failure::OversizedMessage);
    }
    if URL_SAFE_NO_PAD.encode(&bytes) != encoded {
        return Err(Failure::MalformedMessage);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_native_fetch::{
        cloud_sync_commit_protected_page_lease, cloud_sync_open_protected_outbound_message,
        cloud_sync_stage_protected_outbound_envelope,
    };
    use rustpush::cloudkit_proto::{record, Identifier, RecordIdentifier, RecordZoneIdentifier};

    fn binding() -> MessageUpdateBinding {
        MessageUpdateBinding {
            logical_entity_key_hash: "L".repeat(43),
            server_record_id_hash: "S".repeat(43),
            predecessor_etag_hash: "E".repeat(43),
            mutation_source_sha256: "a".repeat(64),
            ids_receipt_binding_sha256: "b".repeat(64),
            reflected_snapshot_sha256: "c".repeat(64),
            auth_binding_sha256: "d".repeat(64),
            writer_epoch: 1,
        }
    }

    fn field(name: &str, bytes: &[u8]) -> record::Field {
        record::Field {
            identifier: Some(record::field::Identifier {
                name: Some(name.into()),
            }),
            value: Some(record::field::Value {
                r#type: Some(Type::EncryptedBytesType as i32),
                is_encrypted: Some(true),
                bytes_value: Some(bytes.to_vec()),
                ..Default::default()
            }),
        }
    }

    fn fixture() -> (Record, RecordSaveRequest) {
        let predecessor = Record {
            record_identifier: Some(RecordIdentifier {
                value: Some(Identifier {
                    name: Some("synthetic-record".into()),
                    r#type: Some(1),
                }),
                zone_identifier: Some(RecordZoneIdentifier {
                    value: Some(Identifier {
                        name: Some("messageManateeZone".into()),
                        r#type: Some(6),
                    }),
                    owner_identifier: Some(Identifier {
                        name: Some("synthetic-owner".into()),
                        r#type: Some(7),
                    }),
                    ..Default::default()
                }),
            }),
            r#type: Some(record::Type {
                name: Some("MessageEncryptedV3".into()),
            }),
            etag: Some("synthetic-predecessor-version".into()),
            pcs_key: Some(vec![1, 2, 3, 4]),
            record_field: vec![
                field("msgProto", b"original-ciphertext"),
                field("future-field", b"opaque"),
            ],
            ..Default::default()
        };
        let request = RecordSaveRequest {
            record: Some(Record {
                record_identifier: predecessor.record_identifier.clone(),
                r#type: predecessor.r#type.clone(),
                pcs_key: predecessor.pcs_key.clone(),
                record_field: vec![field("msgProto", b"prepared-ciphertext")],
                ..Default::default()
            }),
            merge: Some(true),
            save_semantics: Some(1),
            etag: predecessor.etag.clone(),
            ..Default::default()
        };
        (predecessor, request)
    }

    fn commit(path: &std::path::Path, stage: &StagedMessageUpdate) {
        cloud_sync_commit_protected_page_lease(
            path.to_path_buf(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_reference),
        )
        .unwrap();
    }

    #[test]
    fn exact_committed_update_reopens_without_reencrypting_or_refreshing_version() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let account = "A".repeat(43);
        let (previous, request) = fixture();
        let stage = stage_message_update(
            path.clone(),
            account.clone(),
            binding(),
            &previous,
            &request,
        )
        .unwrap();
        assert_eq!(
            open_message_update(path.clone(), account.clone(), &binding(), &stage).err(),
            Some(Failure::ProtectedStorage)
        );
        commit(&path, &stage);
        commit(&path, &stage);
        for _ in 0..2 {
            let recovered =
                open_message_update(path.clone(), account.clone(), &binding(), &stage).unwrap();
            assert_eq!(
                recovered.predecessor().encode_to_vec(),
                previous.encode_to_vec()
            );
            assert_eq!(recovered.request().encode_to_vec(), request.encode_to_vec());
            assert!(recovered.binding() == &binding());
        }
    }

    #[test]
    fn update_rejects_changed_authority_source_attempt_or_descriptor() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let account = "A".repeat(43);
        let (previous, request) = fixture();
        let stage = stage_message_update(
            path.clone(),
            account.clone(),
            binding(),
            &previous,
            &request,
        )
        .unwrap();
        commit(&path, &stage);
        assert!(open_message_update(path.clone(), "B".repeat(43), &binding(), &stage).is_err());
        for mode in 0..8 {
            let mut changed = binding();
            match mode {
                0 => changed.logical_entity_key_hash = "F".repeat(43),
                1 => changed.server_record_id_hash = "F".repeat(43),
                2 => changed.predecessor_etag_hash = "F".repeat(43),
                3 => changed.mutation_source_sha256 = "f".repeat(64),
                4 => changed.ids_receipt_binding_sha256 = "f".repeat(64),
                5 => changed.reflected_snapshot_sha256 = "f".repeat(64),
                6 => changed.auth_binding_sha256 = "f".repeat(64),
                _ => changed.writer_epoch += 1,
            }
            assert_eq!(
                open_message_update(path.clone(), account.clone(), &changed, &stage).err(),
                Some(Failure::BindingMismatch),
                "binding field {mode}"
            );
        }
        let other = stage_message_update(
            path.clone(),
            account.clone(),
            binding(),
            &previous,
            &request,
        )
        .unwrap();
        commit(&path, &other);
        for mode in 0..3 {
            let mut changed = stage.clone();
            match mode {
                0 => changed.payload_sha256 = "f".repeat(64),
                1 => changed.protected_reference = other.protected_reference.clone(),
                _ => changed.lease_reference = other.lease_reference.clone(),
            }
            assert!(
                open_message_update(path.clone(), account.clone(), &binding(), &changed).is_err(),
                "descriptor {mode}"
            );
        }
    }

    #[test]
    fn update_storage_cannot_be_relabelled_as_a_create() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let account = "A".repeat(43);
        let (previous, request) = fixture();
        let stage = stage_message_update(
            path.clone(),
            account.clone(),
            binding(),
            &previous,
            &request,
        )
        .unwrap();
        commit(&path, &stage);
        assert!(cloud_sync_open_protected_outbound_message(
            path.clone(),
            account.clone(),
            &stage.protected_reference
        )
        .is_err());
        let envelope = cloud_sync_open_protected_message_update(
            path.clone(),
            account.clone(),
            &stage.protected_reference,
        )
        .unwrap();
        let create =
            cloud_sync_stage_protected_outbound_envelope(path.clone(), account.clone(), envelope)
                .unwrap();
        let relabelled = StagedMessageUpdate {
            protected_reference: create.protected_envelope_reference,
            lease_reference: create.lease_reference,
            ..stage
        };
        commit(&path, &relabelled);
        assert_eq!(
            open_message_update(path, account, &binding(), &relabelled).err(),
            Some(Failure::ProtectedStorage)
        );
    }

    #[test]
    fn only_exact_versioned_merge_of_message_fields_is_stageable() {
        let (previous, request) = fixture();
        validate_request(&previous, &request).unwrap();
        for mode in 0..15 {
            let mut changed = request.clone();
            match mode {
                0 => changed.etag = None,
                1 => changed.etag = Some("different-version".into()),
                2 => changed.save_semantics = Some(0),
                3 => changed.save_semantics = Some(3),
                4 => changed.merge = Some(false),
                5 => changed
                    .fields_to_delete_if_exist_on_merge
                    .push("future-field".into()),
                6 => changed.record.as_mut().unwrap().pcs_key = Some(vec![5; 4]),
                7 => {
                    changed
                        .record
                        .as_mut()
                        .unwrap()
                        .record_identifier
                        .as_mut()
                        .unwrap()
                        .value
                        .as_mut()
                        .unwrap()
                        .name = Some("another-record".into())
                }
                8 => {
                    changed
                        .record
                        .as_mut()
                        .unwrap()
                        .record_identifier
                        .as_mut()
                        .unwrap()
                        .zone_identifier
                        .as_mut()
                        .unwrap()
                        .owner_identifier
                        .as_mut()
                        .unwrap()
                        .name = Some("another-owner".into())
                }
                9 => changed
                    .record
                    .as_mut()
                    .unwrap()
                    .record_field
                    .push(field("future-field", b"replace")),
                10 => changed
                    .record
                    .as_mut()
                    .unwrap()
                    .record_field
                    .push(field("msgProto", b"duplicate")),
                11 => changed.record.as_mut().unwrap().record_field.clear(),
                12 => {
                    changed.record.as_mut().unwrap().record_field[0]
                        .value
                        .as_mut()
                        .unwrap()
                        .is_encrypted = Some(false)
                }
                13 => {
                    changed.record.as_mut().unwrap().record_field[0]
                        .value
                        .as_mut()
                        .unwrap()
                        .bytes_value = Some(vec![])
                }
                _ => changed.record.as_mut().unwrap().etag = previous.etag.clone(),
            }
            assert!(
                validate_request(&previous, &changed).is_err(),
                "request shape {mode}"
            );
        }
        for mode in 0..5 {
            let mut changed = previous.clone();
            match mode {
                0 => changed.etag = Some(" ".into()),
                1 => changed.pcs_key = Some(vec![1; 5]),
                2 => changed.record_field.push(field("msgProto", b"duplicate")),
                3 => {
                    changed.record_field.remove(0);
                }
                _ => {
                    changed
                        .record_identifier
                        .as_mut()
                        .unwrap()
                        .zone_identifier
                        .as_mut()
                        .unwrap()
                        .value
                        .as_mut()
                        .unwrap()
                        .name = Some("chatManateeZone".into());
                }
            };
            assert!(
                validate_request(&changed, &request).is_err(),
                "predecessor shape {mode}"
            );
        }
    }

    #[test]
    fn bounded_payload_and_binding_validation_precedes_any_staging() {
        for mode in 0..7 {
            let mut changed = binding();
            match mode {
                0 => changed.logical_entity_key_hash.clear(),
                1 => changed.server_record_id_hash = "!".repeat(43),
                2 => changed.predecessor_etag_hash = "E".repeat(42),
                3 => changed.mutation_source_sha256 = "A".repeat(64),
                4 => changed.ids_receipt_binding_sha256 = "A".repeat(64),
                5 => changed.reflected_snapshot_sha256 = "A".repeat(64),
                _ => changed.auth_binding_sha256 = "A".repeat(64),
            }
            assert!(validate_binding(&changed).is_err(), "binding shape {mode}");
        }
        assert!(decode_bounded("", 4).is_err());
        assert!(decode_bounded("YQ==", 4).is_err());
        assert!(decode_bounded(&URL_SAFE_NO_PAD.encode(b"12345"), 4).is_err());
        let (previous, mut request) = fixture();
        request.record.as_mut().unwrap().record_field[0]
            .value
            .as_mut()
            .unwrap()
            .bytes_value = Some(vec![0; MAX_RECORD_BYTES + 1]);
        assert_eq!(
            validate_request(&previous, &request).err(),
            Some(Failure::OversizedMessage)
        );
    }

    fn utm_field(time: f64) -> record::Field {
        let mut value = record::field::Value::default();
        value.r#type = Some(Type::DateType as i32);
        value.date_value.get_or_insert_with(Default::default).time = Some(time);
        record::Field {
            identifier: Some(record::field::Identifier {
                name: Some("utm".into()),
            }),
            value: Some(value),
        }
    }

    fn utm_field_without_time() -> record::Field {
        let mut value = record::field::Value::default();
        value.r#type = Some(Type::DateType as i32);
        record::Field {
            identifier: Some(record::field::Identifier {
                name: Some("utm".into()),
            }),
            value: Some(value),
        }
    }

    #[test]
    fn update_rejects_identical_ciphertext_bytes() {
        let (previous, request) = fixture();
        // The prepared fixture changes the bytes, so it stays valid.
        validate_request(&previous, &request).unwrap();
        // Replaying the predecessor bytes verbatim is a no-op, never an update.
        let mut replay = request.clone();
        replay.record.as_mut().unwrap().record_field[0]
            .value
            .as_mut()
            .unwrap()
            .bytes_value = previous.record_field[0]
            .value
            .as_ref()
            .unwrap()
            .bytes_value
            .clone();
        assert_eq!(
            validate_request(&previous, &replay).err(),
            Some(Failure::MalformedMessage)
        );
    }

    #[test]
    fn update_clock_never_moves_backwards() {
        let (previous, request) = fixture();
        // No clocks on either side keeps the existing optional behavior.
        validate_request(&previous, &request).unwrap();

        let mut before = previous.clone();
        before.record_field.push(utm_field(1_720_000_000.0));

        // A request clock behind the stored clock is rejected.
        let mut behind = request.clone();
        behind
            .record
            .as_mut()
            .unwrap()
            .record_field
            .push(utm_field(1_719_999_999.0));
        assert_eq!(
            validate_request(&before, &behind).err(),
            Some(Failure::MalformedMessage)
        );

        // An equal clock is explicitly allowed.
        let mut equal = request.clone();
        equal
            .record
            .as_mut()
            .unwrap()
            .record_field
            .push(utm_field(1_720_000_000.0));
        validate_request(&before, &equal).unwrap();

        // A clock only on the request side is still accepted.
        validate_request(&previous, &equal).unwrap();

        // A clock only on the stored side is still accepted.
        validate_request(&before, &request).unwrap();

        // A non-finite stored clock is malformed, never treated as absent.
        let mut unparseable = previous.clone();
        unparseable.record_field.push(utm_field(f64::NAN));
        assert_eq!(
            validate_request(&unparseable, &behind).err(),
            Some(Failure::MalformedMessage)
        );
    }

    #[test]
    fn update_rejects_out_of_range_predecessor_clock() {
        let (previous, request) = fixture();
        for time in [
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            0.0,
            -1.0,
            MAX_UTM_TIME + 1.0,
        ] {
            let mut malformed = previous.clone();
            malformed.record_field.push(utm_field(time));
            assert_eq!(
                validate_request(&malformed, &request).err(),
                Some(Failure::MalformedMessage),
                "predecessor clock {time:?} must be rejected"
            );
        }
        // A predecessor clock with no timestamp is malformed, not absent.
        let mut missing = previous.clone();
        missing.record_field.push(utm_field_without_time());
        assert_eq!(
            validate_request(&missing, &request).err(),
            Some(Failure::MalformedMessage)
        );
    }

    #[test]
    fn update_rejects_missing_or_empty_predecessor_ciphertext() {
        let (previous, request) = fixture();
        // A predecessor without the payload field stays malformed.
        let mut missing = previous.clone();
        missing.record_field.remove(0);
        assert_eq!(
            validate_request(&missing, &request).err(),
            Some(Failure::MalformedMessage)
        );
        // An empty predecessor payload is malformed, never skipped.
        let mut empty = previous.clone();
        empty.record_field[0].value.as_mut().unwrap().bytes_value = Some(vec![]);
        assert_eq!(
            validate_request(&empty, &request).err(),
            Some(Failure::MalformedMessage)
        );
        // A predecessor payload without bytes is malformed, never skipped.
        let mut unparseable = previous.clone();
        unparseable.record_field[0]
            .value
            .as_mut()
            .unwrap()
            .bytes_value = None;
        assert_eq!(
            validate_request(&unparseable, &request).err(),
            Some(Failure::MalformedMessage)
        );
    }
}
