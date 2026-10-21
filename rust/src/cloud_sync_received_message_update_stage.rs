//! Restart-stable received conditional update. The source proof is deliberately
//! not an IDS send receipt. Shares only request-shape, lease and readback code
//! with outgoing updates; neither envelope can be opened as the other origin.
#![cfg_attr(not(test), allow(dead_code))]

use crate::{
    cloud_sync_message_update_stage::{
        classify_conditional_update_readback, validate_request, MessageUpdateReadbackState,
        StagedMessageUpdate,
    },
    cloud_sync_native_fetch::{
        cloud_sync_open_protected_message_update, cloud_sync_stage_protected_message_update,
        cloud_sync_verify_committed_lease_exact,
    },
    cloud_sync_outbound::CloudSyncOutboundFailure as Failure,
    cloud_sync_received_source::hex_digest,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use prost::Message;
use rustpush::cloudkit_proto::{Record, RecordSaveRequest};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const DOMAIN: &str = "cloud-sync-received-message-conditional-update";
const MAX_ENVELOPE_BYTES: usize = 9 * 1024 * 1024;
const MAX_RECORD_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ReceivedMessageUpdateBinding {
    pub(crate) logical_entity_key_hash: String,
    pub(crate) server_record_id_hash: String,
    pub(crate) predecessor_etag_hash: String,
    pub(crate) mutation_source_sha256: String,
    pub(crate) mutation_guid_hash: String,
    pub(crate) target_guid_hash: String,
    pub(crate) native_predecessor_proof_sha256: String,
    pub(crate) reflected_snapshot_sha256: String,
    pub(crate) auth_binding_sha256: String,
    pub(crate) writer_epoch: u64,
    pub(crate) raw_generation: u64,
}

/// Journal correlation supplied at recovery. The original-author proof is
/// recovered only from the native-authenticated envelope, never invented by
/// Dart or substituted for an outgoing IDS receipt.
pub(crate) struct ReceivedMessageUpdateContext {
    pub(crate) logical_entity_key_hash: String,
    pub(crate) server_record_id_hash: String,
    pub(crate) predecessor_etag_hash: String,
    pub(crate) mutation_source_sha256: String,
    pub(crate) mutation_guid_hash: String,
    pub(crate) target_guid_hash: String,
    pub(crate) reflected_snapshot_sha256: String,
    pub(crate) auth_binding_sha256: String,
    pub(crate) writer_epoch: u64,
    pub(crate) raw_generation: u64,
}

impl ReceivedMessageUpdateContext {
    fn matches(&self, binding: &ReceivedMessageUpdateBinding) -> bool {
        self.logical_entity_key_hash == binding.logical_entity_key_hash
            && self.server_record_id_hash == binding.server_record_id_hash
            && self.predecessor_etag_hash == binding.predecessor_etag_hash
            && self.mutation_source_sha256 == binding.mutation_source_sha256
            && self.mutation_guid_hash == binding.mutation_guid_hash
            && self.target_guid_hash == binding.target_guid_hash
            && self.reflected_snapshot_sha256 == binding.reflected_snapshot_sha256
            && self.auth_binding_sha256 == binding.auth_binding_sha256
            && self.writer_epoch == binding.writer_epoch
            && self.raw_generation == binding.raw_generation
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    domain: String,
    version: u32,
    binding: ReceivedMessageUpdateBinding,
    predecessor_b64: String,
    request_b64: String,
}

// Deliberately not Debug/serde: decrypted record data stays native.
pub(crate) struct OpenedReceivedMessageUpdate {
    predecessor: Record,
    request: RecordSaveRequest,
    binding: ReceivedMessageUpdateBinding,
}

impl OpenedReceivedMessageUpdate {
    pub(crate) fn predecessor(&self) -> &Record {
        &self.predecessor
    }
    pub(crate) fn request(&self) -> &RecordSaveRequest {
        &self.request
    }
    pub(crate) fn binding(&self) -> &ReceivedMessageUpdateBinding {
        &self.binding
    }
    pub(crate) fn classify_readback(&self, remote: &Record) -> MessageUpdateReadbackState {
        classify_conditional_update_readback(&self.predecessor, &self.request, remote)
    }
}

pub(crate) fn stage_received_message_update(
    directory: PathBuf,
    account: String,
    binding: ReceivedMessageUpdateBinding,
    predecessor: &Record,
    request: &RecordSaveRequest,
) -> Result<StagedMessageUpdate, Failure> {
    validate_binding(&binding)?;
    validate_request(predecessor, request)?;
    let envelope = Envelope {
        domain: DOMAIN.into(),
        version: 1,
        binding,
        predecessor_b64: URL_SAFE_NO_PAD.encode(predecessor.encode_to_vec()),
        request_b64: URL_SAFE_NO_PAD.encode(request.encode_to_vec()),
    };
    let bytes = serde_json::to_vec(&envelope).map_err(|_| Failure::MalformedMessage)?;
    if bytes.len() > MAX_ENVELOPE_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let protected = cloud_sync_stage_protected_message_update(
        directory,
        account,
        URL_SAFE_NO_PAD.encode(&bytes),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    Ok(StagedMessageUpdate {
        protected_reference: protected.protected_envelope_reference,
        lease_reference: protected.lease_reference,
        payload_sha256: hex_digest(&bytes),
    })
}

pub(crate) fn open_received_message_update(
    directory: PathBuf,
    account: String,
    expected: &ReceivedMessageUpdateBinding,
    stage: &StagedMessageUpdate,
) -> Result<OpenedReceivedMessageUpdate, Failure> {
    validate_binding(expected)?;
    let opened = open_authenticated_received_message_update(directory, account, stage)?;
    if opened.binding != *expected {
        return Err(Failure::BindingMismatch);
    }
    Ok(opened)
}

/// Open only a committed native stage and compare every restart-stable journal
/// field. The original native proof is authenticated by the protector and
/// remains private inside this result; no generic plaintext staging API exists.
pub(crate) fn open_received_message_update_for_context(
    directory: PathBuf,
    account: String,
    expected: &ReceivedMessageUpdateContext,
    stage: &StagedMessageUpdate,
) -> Result<OpenedReceivedMessageUpdate, Failure> {
    let opened = open_authenticated_received_message_update(directory, account, stage)?;
    if !expected.matches(&opened.binding) {
        return Err(Failure::BindingMismatch);
    }
    Ok(opened)
}

fn open_authenticated_received_message_update(
    directory: PathBuf,
    account: String,
    stage: &StagedMessageUpdate,
) -> Result<OpenedReceivedMessageUpdate, Failure> {
    if !digest(&stage.payload_sha256) {
        return Err(Failure::MalformedMessage);
    }
    cloud_sync_verify_committed_lease_exact(
        directory.clone(),
        &stage.lease_reference,
        std::slice::from_ref(&stage.protected_reference),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let encoded =
        cloud_sync_open_protected_message_update(directory, account, &stage.protected_reference)
            .map_err(|_| Failure::ProtectedStorage)?;
    let bytes = decode(&encoded, MAX_ENVELOPE_BYTES)?;
    if hex_digest(&bytes) != stage.payload_sha256 {
        return Err(Failure::BindingMismatch);
    }
    let envelope: Envelope =
        serde_json::from_slice(&bytes).map_err(|_| Failure::MalformedMessage)?;
    if envelope.domain != DOMAIN
        || envelope.version != 1
        || serde_json::to_vec(&envelope).map_err(|_| Failure::MalformedMessage)? != bytes
    {
        return Err(Failure::BindingMismatch);
    }
    validate_binding(&envelope.binding)?;
    let predecessor_bytes = decode(&envelope.predecessor_b64, MAX_RECORD_BYTES)?;
    let request_bytes = decode(&envelope.request_b64, MAX_RECORD_BYTES)?;
    let predecessor =
        Record::decode(predecessor_bytes.as_slice()).map_err(|_| Failure::MalformedMessage)?;
    let request = RecordSaveRequest::decode(request_bytes.as_slice())
        .map_err(|_| Failure::MalformedMessage)?;
    if predecessor.encode_to_vec() != predecessor_bytes || request.encode_to_vec() != request_bytes
    {
        return Err(Failure::MalformedMessage);
    }
    validate_request(&predecessor, &request)?;
    Ok(OpenedReceivedMessageUpdate {
        predecessor,
        request,
        binding: envelope.binding,
    })
}

fn validate_binding(binding: &ReceivedMessageUpdateBinding) -> Result<(), Failure> {
    if [
        &binding.logical_entity_key_hash,
        &binding.server_record_id_hash,
        &binding.predecessor_etag_hash,
    ]
    .iter()
    .any(|v| {
        v.len() != 43
            || !v
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
    }) || [
        &binding.mutation_source_sha256,
        &binding.mutation_guid_hash,
        &binding.target_guid_hash,
        &binding.native_predecessor_proof_sha256,
        &binding.reflected_snapshot_sha256,
        &binding.auth_binding_sha256,
    ]
    .iter()
    .any(|v| !digest(v))
        || binding.writer_epoch == 0
        || binding.raw_generation == 0
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}

fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
}
fn decode(value: &str, max: usize) -> Result<Vec<u8>, Failure> {
    if value.is_empty() || value.len() > max.div_ceil(3) * 4 {
        return Err(Failure::OversizedMessage);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| Failure::MalformedMessage)?;
    if bytes.len() > max || URL_SAFE_NO_PAD.encode(&bytes) != value {
        return Err(Failure::MalformedMessage);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_message_update_stage::{
        open_message_update, stage_message_update, MessageUpdateBinding,
    };
    use crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease;

    fn binding() -> ReceivedMessageUpdateBinding {
        ReceivedMessageUpdateBinding {
            logical_entity_key_hash: "L".repeat(43),
            server_record_id_hash: "S".repeat(43),
            predecessor_etag_hash: "E".repeat(43),
            mutation_source_sha256: "a".repeat(64),
            mutation_guid_hash: "b".repeat(64),
            target_guid_hash: "c".repeat(64),
            native_predecessor_proof_sha256: "d".repeat(64),
            reflected_snapshot_sha256: "e".repeat(64),
            auth_binding_sha256: "f".repeat(64),
            writer_epoch: 2,
            raw_generation: 7,
        }
    }
    fn outgoing() -> MessageUpdateBinding {
        MessageUpdateBinding {
            logical_entity_key_hash: "L".repeat(43),
            server_record_id_hash: "S".repeat(43),
            predecessor_etag_hash: "E".repeat(43),
            mutation_source_sha256: "a".repeat(64),
            ids_receipt_binding_sha256: "b".repeat(64),
            reflected_snapshot_sha256: "e".repeat(64),
            auth_binding_sha256: "f".repeat(64),
            writer_epoch: 2,
            raw_generation: 7,
        }
    }
    fn commit(path: &std::path::Path, stage: &StagedMessageUpdate) {
        cloud_sync_commit_protected_page_lease(
            path.to_owned(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_reference),
        )
        .unwrap();
    }

    #[test]
    fn received_conditional_update_reopens_exact_attempt_and_classifies_lost_return() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let (predecessor, request) = crate::cloud_sync_message_update_stage::tests::fixture();
        let stage = stage_received_message_update(
            path.clone(),
            "A".repeat(43),
            binding(),
            &predecessor,
            &request,
        )
        .unwrap();
        assert!(
            open_received_message_update(path.clone(), "A".repeat(43), &binding(), &stage).is_err()
        );
        commit(&path, &stage);
        let opened =
            open_received_message_update(path.clone(), "A".repeat(43), &binding(), &stage).unwrap();
        assert_eq!(opened.request(), &request);
        assert_eq!(opened.predecessor(), &predecessor);
        assert!(opened.binding() == &binding());
        assert_eq!(
            opened.classify_readback(&predecessor),
            MessageUpdateReadbackState::NotApplied
        );
        let mut remote = predecessor.clone();
        remote.etag = Some("new-server-version".into());
        remote.record_field[0] = request.record.as_ref().unwrap().record_field[0].clone();
        assert_eq!(
            opened.classify_readback(&remote),
            MessageUpdateReadbackState::Committed
        );
        remote.record_field[1].value.as_mut().unwrap().bytes_value =
            Some(b"changed-opaque".to_vec());
        assert_eq!(
            opened.classify_readback(&remote),
            MessageUpdateReadbackState::Diverged
        );
        assert!(open_received_message_update(path, "B".repeat(43), &binding(), &stage).is_err());
    }

    #[test]
    fn received_and_outgoing_update_proofs_are_not_interchangeable() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let (previous, request) = crate::cloud_sync_message_update_stage::tests::fixture();
        let received = stage_received_message_update(
            path.clone(),
            "A".repeat(43),
            binding(),
            &previous,
            &request,
        )
        .unwrap();
        commit(&path, &received);
        assert!(open_message_update(path.clone(), "A".repeat(43), &outgoing(), &received).is_err());
        let sent = stage_message_update(
            path.clone(),
            "A".repeat(43),
            outgoing(),
            &previous,
            &request,
        )
        .unwrap();
        commit(&path, &sent);
        assert!(open_received_message_update(path, "A".repeat(43), &binding(), &sent).is_err());
    }

    #[test]
    fn received_update_binding_rejects_any_predecessor_or_generation_swap() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let (previous, request) = crate::cloud_sync_message_update_stage::tests::fixture();
        let stage = stage_received_message_update(
            path.clone(),
            "A".repeat(43),
            binding(),
            &previous,
            &request,
        )
        .unwrap();
        commit(&path, &stage);
        for variant in 0..11 {
            let mut changed = binding();
            match variant {
                0 => changed.logical_entity_key_hash = "Q".repeat(43),
                1 => changed.server_record_id_hash = "Q".repeat(43),
                2 => changed.predecessor_etag_hash = "Q".repeat(43),
                3 => changed.mutation_source_sha256 = "0".repeat(64),
                4 => changed.mutation_guid_hash = "0".repeat(64),
                5 => changed.target_guid_hash = "0".repeat(64),
                6 => changed.native_predecessor_proof_sha256 = "0".repeat(64),
                7 => changed.reflected_snapshot_sha256 = "0".repeat(64),
                8 => changed.auth_binding_sha256 = "0".repeat(64),
                9 => changed.writer_epoch += 1,
                _ => changed.raw_generation += 1,
            }
            assert!(
                open_received_message_update(path.clone(), "A".repeat(43), &changed, &stage)
                    .is_err()
            );
        }
        let mut create = request.clone();
        create.save_semantics = Some(0);
        assert!(
            stage_received_message_update(path, "A".repeat(43), binding(), &previous, &create)
                .is_err()
        );
    }
}
