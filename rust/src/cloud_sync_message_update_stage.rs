//! Retain one exact conditional message update under a committed protected lease.
//! No network, claims, IDS resend, ETag refresh, or save authority lives here.
//! The caller must prove mutation source/receipt and current account before
//! staging, then bind this immutable attempt into its journal before commit.
#![cfg_attr(not(test), allow(dead_code))]

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use prost::Message;
use rustpush::cloudkit::CloudKitRequestIdentity;
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
    pub(crate) mutation_source_sha256: String,
    pub(crate) ids_receipt_binding_sha256: String,
    pub(crate) reflected_snapshot_sha256: String,
    pub(crate) auth_binding_sha256: String,
    pub(crate) writer_epoch: u64,
    pub(crate) local_operation_id: String,
    pub(crate) http_request_uuid: String,
    pub(crate) apple_operation_uuid: String,
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
    pub(crate) payload_length: u64,
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
        payload_length: bytes.len() as u64,
    })
}

pub(crate) fn open_message_update(
    directory: PathBuf,
    account_fingerprint: String,
    expected: &MessageUpdateBinding,
    stage: &StagedMessageUpdate,
) -> Result<OpenedMessageUpdate, Failure> {
    validate_binding(expected)?;
    if !is_digest(&stage.payload_sha256)
        || stage.payload_length == 0
        || stage.payload_length > MAX_ENVELOPE_BYTES as u64
    {
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
    if bytes.len() as u64 != stage.payload_length || digest(&bytes) != stage.payload_sha256 {
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
    if [
        &binding.mutation_source_sha256,
        &binding.ids_receipt_binding_sha256,
        &binding.reflected_snapshot_sha256,
        &binding.auth_binding_sha256,
    ]
    .iter()
    .any(|value| !is_digest(value))
        || binding.local_operation_id.is_empty()
        || binding.local_operation_id.len() > 256
        || !binding
            .local_operation_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        || binding.http_request_uuid == binding.apple_operation_uuid
    {
        return Err(Failure::MalformedMessage);
    }
    CloudKitRequestIdentity::new(
        binding.http_request_uuid.clone(),
        vec![binding.apple_operation_uuid.clone()],
    )
    .map_err(|_| Failure::MalformedMessage)?;
    Ok(())
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
                if !time.is_finite() || time <= 0.0 || time > 252_423_993_599.0 {
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
    Ok(())
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
            mutation_source_sha256: "a".repeat(64),
            ids_receipt_binding_sha256: "b".repeat(64),
            reflected_snapshot_sha256: "c".repeat(64),
            auth_binding_sha256: "d".repeat(64),
            writer_epoch: 1,
            local_operation_id: "mutation-test-01".into(),
            http_request_uuid: "11111111-1111-4111-8111-111111111111".into(),
            apple_operation_uuid: "22222222-2222-4222-8222-222222222222".into(),
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
                0 => changed.mutation_source_sha256 = "f".repeat(64),
                1 => changed.ids_receipt_binding_sha256 = "f".repeat(64),
                2 => changed.reflected_snapshot_sha256 = "f".repeat(64),
                3 => changed.auth_binding_sha256 = "f".repeat(64),
                4 => changed.writer_epoch += 1,
                5 => changed.local_operation_id.push('2'),
                6 => changed.http_request_uuid = "33333333-3333-4333-8333-333333333333".into(),
                _ => changed.apple_operation_uuid = "44444444-4444-4444-8444-444444444444".into(),
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
        for mode in 0..4 {
            let mut changed = stage.clone();
            match mode {
                0 => changed.payload_length += 1,
                1 => changed.payload_sha256 = "f".repeat(64),
                2 => changed.protected_reference = other.protected_reference.clone(),
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
        for mode in 0..6 {
            let mut changed = binding();
            match mode {
                0 => changed.mutation_source_sha256 = "A".repeat(64),
                1 => changed.local_operation_id.clear(),
                2 => changed.local_operation_id = "not an operation".into(),
                3 => changed.local_operation_id = "x".repeat(257),
                4 => changed.http_request_uuid = "bad-uuid".into(),
                _ => changed.apple_operation_uuid = changed.http_request_uuid.clone(),
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
}
