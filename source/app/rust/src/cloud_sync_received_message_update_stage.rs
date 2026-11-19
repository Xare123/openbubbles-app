//! Restart-stable received conditional update. The source proof is deliberately
//! not an IDS send receipt. Shares only request-shape, lease and readback code
//! with outgoing updates; neither envelope can be opened as the other origin.
#![cfg_attr(not(test), allow(dead_code))]

use crate::{
    cloud_sync_message_update_stage::{
        classify_conditional_update_readback_with_presence,
        classify_without_source_metadata_witness, decode_message_update_predecessor,
        protection_metadata_presence, validate_request, MessageUpdateReadbackState,
        ProtectionMetadataPresence, StagedMessageUpdate,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    predecessor_field31_present: Option<bool>,
}

// Deliberately not Debug/serde: decrypted record data stays native.
pub(crate) struct OpenedReceivedMessageUpdate {
    predecessor: Record,
    request: RecordSaveRequest,
    binding: ReceivedMessageUpdateBinding,
    protection_metadata: Option<ProtectionMetadataPresence>,
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
        classify_without_source_metadata_witness(&self.predecessor, &self.request, remote)
    }
    pub(crate) fn classify_readback_with_wire(
        &self,
        remote: &Record,
        remote_wire: &[u8],
    ) -> MessageUpdateReadbackState {
        match self.protection_metadata {
            Some(metadata) => classify_conditional_update_readback_with_presence(
                &self.predecessor,
                &self.request,
                remote,
                metadata,
                remote_wire,
            ),
            None => classify_without_source_metadata_witness(
                &self.predecessor,
                &self.request,
                remote,
            ),
        }
    }
}

pub(crate) fn stage_received_message_update(
    directory: PathBuf,
    account: String,
    binding: ReceivedMessageUpdateBinding,
    predecessor: &Record,
    request: &RecordSaveRequest,
) -> Result<StagedMessageUpdate, Failure> {
    stage_received_message_update_with_wire(directory, account, binding, predecessor, request, None)
}

pub(crate) fn stage_received_message_update_with_wire(
    directory: PathBuf,
    account: String,
    binding: ReceivedMessageUpdateBinding,
    predecessor: &Record,
    request: &RecordSaveRequest,
    predecessor_wire: Option<&[u8]>,
) -> Result<StagedMessageUpdate, Failure> {
    validate_binding(&binding)?;
    validate_request(predecessor, request)?;
    let predecessor_field31_present = if let Some(raw) = predecessor_wire {
        let decoded = Record::decode(raw).map_err(|_| Failure::MalformedMessage)?;
        if decoded != *predecessor {
            return Err(Failure::BindingMismatch);
        }
        Some(
            protection_metadata_presence(raw)
                .map_err(|_| Failure::MalformedMessage)?
                .field31_present,
        )
    } else {
        None
    };
    let envelope = Envelope {
        domain: DOMAIN.into(),
        version: 2,
        binding,
        predecessor_b64: URL_SAFE_NO_PAD.encode(predecessor.encode_to_vec()),
        request_b64: URL_SAFE_NO_PAD.encode(request.encode_to_vec()),
        predecessor_field31_present,
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
        || !matches!(envelope.version, 1 | 2)
        || serde_json::to_vec(&envelope).map_err(|_| Failure::MalformedMessage)? != bytes
    {
        return Err(Failure::BindingMismatch);
    }
    validate_binding(&envelope.binding)?;
    let predecessor_bytes = decode(&envelope.predecessor_b64, MAX_RECORD_BYTES)?;
    let request_bytes = decode(&envelope.request_b64, MAX_RECORD_BYTES)?;
    let predecessor = decode_message_update_predecessor(predecessor_bytes.as_slice())?;
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
        protection_metadata: envelope.predecessor_field31_present.map(|field31_present| {
            ProtectionMetadataPresence { field31_present }
        }),
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
        let predecessor_wire = predecessor.encode_to_vec();
        let present_empty_wire = [vec![0xfa, 0x01, 0x00], predecessor_wire.clone()].concat();
        let stage = stage_received_message_update_with_wire(
            path.clone(),
            "A".repeat(43),
            binding(),
            &predecessor,
            &request,
            Some(&present_empty_wire),
        )
        .unwrap();
        assert!(
            open_received_message_update(path.clone(), "A".repeat(43), &binding(), &stage).is_err()
        );
        commit(&path, &stage);
        let mut tampered_stage = stage.clone();
        tampered_stage.payload_sha256 = "0".repeat(64);
        assert!(
            open_received_message_update(
                path.clone(), "A".repeat(43), &binding(), &tampered_stage,
            )
            .is_err(),
            "the protected payload hash binds the v2 field31 witness",
        );
        let opened =
            open_received_message_update(path.clone(), "A".repeat(43), &binding(), &stage).unwrap();
        assert_eq!(opened.request(), &request);
        assert_eq!(opened.predecessor(), &predecessor);
        assert!(opened.binding() == &binding());
        assert_eq!(opened.classify_readback(&predecessor), MessageUpdateReadbackState::Diverged,
            "typed readback without exact wire cannot compare field31");
        assert_eq!(opened.classify_readback_with_wire(&predecessor, &predecessor_wire),
            MessageUpdateReadbackState::Diverged, "absent31 is not the staged present-empty31 source");
        let reordered_present_empty_wire = [predecessor_wire.clone(), vec![0xfa, 0x01, 0x00]].concat();
        assert_eq!(opened.classify_readback_with_wire(&predecessor, &reordered_present_empty_wire),
            MessageUpdateReadbackState::NotApplied, "outer-field reordering preserves equal metadata presence");
        let mut remote = predecessor.clone();
        remote.etag = Some("new-server-version".into());
        remote.record_field[0] = request.record.as_ref().unwrap().record_field[0].clone();
        let committed_wire = [remote.encode_to_vec(), vec![0xfa, 0x01, 0x00]].concat();
        assert_eq!(
            opened.classify_readback_with_wire(&remote, &committed_wire),
            MessageUpdateReadbackState::Committed
        );
        remote.record_field[1].value.as_mut().unwrap().bytes_value =
            Some(b"changed-opaque".to_vec());
        let changed_wire = [remote.encode_to_vec(), vec![0xfa, 0x01, 0x00]].concat();
        assert_eq!(
            opened.classify_readback_with_wire(&remote, &changed_wire),
            MessageUpdateReadbackState::Diverged
        );
        assert!(open_received_message_update(path, "B".repeat(43), &binding(), &stage).is_err());
    }

    #[test]
    fn legacy_v1_cold_reopen_without_field31_witness_cannot_claim_commit() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let account = "A".repeat(43);
        let (predecessor, request) = crate::cloud_sync_message_update_stage::tests::fixture();
        let envelope = Envelope {
            domain: DOMAIN.into(),
            version: 1,
            binding: binding(),
            predecessor_b64: URL_SAFE_NO_PAD.encode(predecessor.encode_to_vec()),
            request_b64: URL_SAFE_NO_PAD.encode(request.encode_to_vec()),
            predecessor_field31_present: None,
        };
        let bytes = serde_json::to_vec(&envelope).unwrap();
        let protected = cloud_sync_stage_protected_message_update(
            path.clone(),
            account.clone(),
            URL_SAFE_NO_PAD.encode(&bytes),
        )
        .unwrap();
        let stage = StagedMessageUpdate {
            protected_reference: protected.protected_envelope_reference,
            lease_reference: protected.lease_reference,
            payload_sha256: hex_digest(&bytes),
        };
        commit(&path, &stage);
        let cold = open_received_message_update(path, account, &binding(), &stage).unwrap();
        let mut committed = predecessor.clone();
        committed.etag = Some("legacy-v1-committed-version".into());
        committed.record_field[0] = request.record.as_ref().unwrap().record_field[0].clone();
        let remote_wire = [committed.encode_to_vec(), vec![0xfa, 0x01, 0x00]].concat();
        assert_eq!(
            cold.classify_readback_with_wire(&committed, &remote_wire),
            MessageUpdateReadbackState::Diverged,
            "v1 lost the field31 witness and cannot prove a matching readback",
        );
    }

    #[test]
    fn field34_survives_projection_protected_restart_and_received_update_encoding() {
        // A measurement-only proto view works before the generated Record learns
        // field34, so the regression fails on actual value loss, not compilation.
        #[derive(Clone, PartialEq, prost::Message)]
        struct TimestampProbe {
            #[prost(bytes = "vec", optional, tag = "34")]
            value: Option<Vec<u8>>,
        }
        fn metadata(raw: &[u8]) -> Option<Vec<u8>> {
            TimestampProbe::decode(raw).unwrap().value
        }
        fn append(raw: &mut Vec<u8>, value: &[u8]) {
            raw.extend([0x92, 0x02]);
            assert!(value.len() < 128);
            raw.push(value.len() as u8);
            raw.extend(value);
        }
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let account = "A".repeat(43);
        // Absent, explicit empty, present domain0, creation/modification-empty,
        // and independent Version fields with explicit zero/empty values.
        for expected in [None, Some(vec![]), Some(vec![8, 0]),
            Some(vec![18, 0]), Some(vec![26, 0]),
            Some(vec![8, 2, 18, 6, 8, 0, 18, 0, 24, 0, 26, 0])] {
            let (original, request) = crate::cloud_sync_message_update_stage::tests::fixture();
            let mut wire = original.encode_to_vec();
            if let Some(value) = &expected { append(&mut wire, value); }
            let typed = Record::decode(wire.as_slice()).unwrap();
            let retained = crate::cloud_sync_native_fetch::cloud_sync_stage_protected_received_record_readback(
                path.clone(), account.clone(), 7, &typed, &wire).unwrap();
            crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
                path.clone(), &retained.lease_reference,
                std::slice::from_ref(&retained.protected_raw_record_reference)).unwrap();
            // The production open function constructs a fresh store/DPAPI scope;
            // no in-memory Record is used as the recovered source.
            drop(typed);
            let scope = crate::cloud_sync_native_fetch::CloudNativeProtectionScope::new(
                account.clone(), crate::cloud_sync_native_fetch::CloudNativeStream::Messages).unwrap();
            let reopened = crate::cloud_sync_native_fetch::cloud_sync_unprotect_raw_envelope(
                path.clone(), &scope, crate::cloud_sync_native_fetch::CloudNativeStream::Messages,
                7, &retained.protected_raw_record_reference).unwrap();
            assert_eq!(reopened.raw(), Some(wire.as_slice()));
            let projected = crate::cloud_sync_transient_bridge::decode_projection_record(reopened.raw().unwrap()).unwrap();
            let predecessor = crate::cloud_sync_message_update_stage::decode_message_update_predecessor(
                reopened.raw().unwrap()).unwrap();
            let stage = stage_received_message_update_with_wire(path.clone(), account.clone(), binding(),
                &predecessor, &request, Some(wire.as_slice())).unwrap();
            commit(&path, &stage);
            drop(predecessor);
            let cold = open_received_message_update(path.clone(), account.clone(), &binding(), &stage).unwrap();
            assert_eq!(cold.predecessor().record_identifier, original.record_identifier);
            assert_eq!(cold.predecessor().etag, original.etag);
            assert_eq!(cold.predecessor().pcs_key, original.pcs_key);
            assert_eq!(metadata(&projected.encode_to_vec()), expected, "projection lost field34");
            assert_eq!(metadata(&cold.predecessor().encode_to_vec()), expected, "received update encoding lost field34");
            assert_eq!(cold.request(), &request);
        }
    }

    #[test]
    fn field34_presence_or_value_change_is_not_the_same_predecessor() {
        let (base, _) = crate::cloud_sync_message_update_stage::tests::fixture();
        let raw = base.encode_to_vec();
        for (left, right) in [(vec![], vec![0x92, 2, 0]),
            (vec![0x92, 2, 0], vec![0x92, 2, 2, 8, 0]),
            (vec![0x92, 2, 2, 8, 0], vec![0x92, 2, 2, 8, 1])] {
            let left = crate::cloud_sync_message_update_stage::decode_message_update_predecessor(
                &[raw.clone(), left].concat()).unwrap();
            let right = crate::cloud_sync_message_update_stage::decode_message_update_predecessor(
                &[raw.clone(), right].concat()).unwrap();
            assert!(!crate::cloud_sync_message_update_stage::predecessor_matches_remote(&left, &right),
                "field34 presence/value loss made distinct predecessors equal");
        }
    }

    #[test]
    fn field34_raw_guards_reject_lossy_metadata_before_generated_decode() {
        let (base, _) = crate::cloud_sync_message_update_stage::tests::fixture();
        let raw = base.encode_to_vec();
        // All are well-framed protobuf; generated decoding can discard or merge
        // these distinctions. Both actual decode boundaries must refuse first.
        for metadata in [vec![0x92, 2, 2, 8, 3], vec![0x92, 2, 2, 32, 0],
            vec![0x92, 2, 4, 18, 2, 32, 0], vec![0x92, 2, 4, 8, 0, 8, 0],
            vec![0x92, 2, 0, 0x92, 2, 0]] {
            let wire = [raw.clone(), metadata].concat();
            assert!(Record::decode(wire.as_slice()).is_ok());
            assert!(crate::cloud_sync_transient_bridge::decode_projection_record(&wire).is_err());
            assert!(crate::cloud_sync_message_update_stage::decode_message_update_predecessor(&wire).is_err());
        }
        // Existing ordinary-history outer opacity remains. Exact received fetch
        // has its separate closed admission gate and never gets this fallback.
        let opaque = [raw, vec![0xc0, 0x3e, 1, 0x92, 2, 2, 8, 0]].concat();
        let projected = crate::cloud_sync_transient_bridge::decode_projection_record(&opaque).unwrap();
        assert_eq!(projected.timestamps.unwrap().domain, Some(0));
    }

    #[test]
    fn field34_cannot_be_injected_as_conditional_write_authority() {
        let directory = tempfile::tempdir().unwrap();
        let (mut previous, mut request) = crate::cloud_sync_message_update_stage::tests::fixture();
        previous.timestamps = Some(rustpush::cloudkit_proto::RecordTimestamps { domain: Some(3), ..Default::default() });
        assert!(stage_received_message_update(directory.path().to_owned(), "A".repeat(43), binding(), &previous, &request).is_err());
        previous.timestamps.as_mut().unwrap().domain = Some(0);
        request.record.as_mut().unwrap().timestamps = previous.timestamps.clone();
        assert!(stage_received_message_update(directory.path().to_owned(), "A".repeat(43), binding(), &previous, &request).is_err());
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
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
