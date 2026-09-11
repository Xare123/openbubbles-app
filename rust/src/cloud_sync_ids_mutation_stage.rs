//! Native-only protected staging for the exact edit/unsend intent codec.
//!
//! Stages canonical bytes from the ids mutation source codec under their own
//! IdsMutationSource protection purpose. Pins an immutable caller-supplied
//! source SHA-256 beside the exact bytes, returns only opaque references plus
//! a digest/length descriptor, and requires a committed exact lease reopen.
//!
//! Not the mutation authorizer: no resend, override, initial-create, network,
//! send, or save. Reconstruction goes through the codec, which revalidates
//! canonical form and lengths. No Debug impls here by design.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_ids_mutation_source::{
    encode_mutation_source, open_mutation_source, validate_mutation_source, OpenedMutationSource,
};
use crate::cloud_sync_native_fetch::{
    cloud_sync_open_protected_ids_mutation_source, cloud_sync_stage_protected_ids_mutation_source,
    cloud_sync_verify_committed_lease_exact,
};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rustpush::MessageInst;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::PathBuf;

const WRAPPER_VERSION: u32 = 1;
const MAX_SOURCE_BYTES: usize = 1024 * 1024;
const MAX_WRAPPER_BYTES: usize = 1024 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct MutationSourceStageV1 {
    v: u32,
    local_source_sha256: String,
    source_b64: String,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct NativeIdsMutationSourceStage {
    pub(crate) protected_reference: String,
    pub(crate) lease_reference: String,
    pub(crate) payload_sha256: String,
    pub(crate) payload_length: u64,
}

pub(crate) fn stage_ids_mutation_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    local_source_sha256: &str,
    msg: &MessageInst,
) -> Result<NativeIdsMutationSourceStage, Failure> {
    validate_source_sha(local_source_sha256)?;
    let source = encode_mutation_source(msg)?;
    if source.is_empty() || source.len() > MAX_SOURCE_BYTES {
        return Err(Failure::MalformedMessage);
    }
    let wrapper = MutationSourceStageV1 {
        v: WRAPPER_VERSION,
        local_source_sha256: local_source_sha256.to_owned(),
        source_b64: URL_SAFE_NO_PAD.encode(&source),
    };
    let wrapper_bytes = serde_json::to_vec(&wrapper).map_err(|_| Failure::MalformedMessage)?;
    if wrapper_bytes.is_empty() || wrapper_bytes.len() > MAX_WRAPPER_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let payload_sha256 = sha256_hex(&wrapper_bytes);
    let payload_length =
        u64::try_from(wrapper_bytes.len()).map_err(|_| Failure::OversizedMessage)?;
    let staged = cloud_sync_stage_protected_ids_mutation_source(
        storage_directory,
        account_fingerprint,
        URL_SAFE_NO_PAD.encode(&wrapper_bytes),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if staged.protected_envelope_reference.is_empty() || staged.lease_reference.is_empty() {
        return Err(Failure::ProtectedStorage);
    }
    Ok(NativeIdsMutationSourceStage {
        protected_reference: staged.protected_envelope_reference,
        lease_reference: staged.lease_reference,
        payload_sha256,
        payload_length,
    })
}

pub(crate) fn open_staged_mutation_source_envelope(
    storage_directory: PathBuf,
    account_fingerprint: String,
    local_source_sha256: &str,
    stage: &NativeIdsMutationSourceStage,
) -> Result<Vec<u8>, Failure> {
    validate_source_sha(local_source_sha256)?;
    validate_stage(stage)?;
    cloud_sync_verify_committed_lease_exact(
        storage_directory.clone(),
        &stage.lease_reference,
        std::slice::from_ref(&stage.protected_reference),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let value = cloud_sync_open_protected_ids_mutation_source(
        storage_directory,
        account_fingerprint,
        &stage.protected_reference,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if value.len() > MAX_WRAPPER_BYTES.div_ceil(3) * 4 {
        return Err(Failure::OversizedMessage);
    }
    let wrapper_bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| Failure::MalformedMessage)?;
    if wrapper_bytes.is_empty()
        || wrapper_bytes.len() > MAX_WRAPPER_BYTES
        || sha256_hex(&wrapper_bytes) != stage.payload_sha256
        || wrapper_bytes.len() as u64 != stage.payload_length
    {
        return Err(Failure::BindingMismatch);
    }
    let wrapper: MutationSourceStageV1 =
        serde_json::from_slice(&wrapper_bytes).map_err(|_| Failure::MalformedMessage)?;
    if wrapper.v != WRAPPER_VERSION {
        return Err(Failure::MalformedMessage);
    }
    validate_source_sha(&wrapper.local_source_sha256)?;
    let canonical = serde_json::to_vec(&wrapper).map_err(|_| Failure::MalformedMessage)?;
    if canonical != wrapper_bytes {
        return Err(Failure::MalformedMessage);
    }
    if wrapper.local_source_sha256 != local_source_sha256 {
        return Err(Failure::BindingMismatch);
    }
    let raw = URL_SAFE_NO_PAD
        .decode(&wrapper.source_b64)
        .map_err(|_| Failure::MalformedMessage)?;
    if URL_SAFE_NO_PAD.encode(&raw) != wrapper.source_b64 {
        return Err(Failure::MalformedMessage);
    }
    if raw.is_empty() || raw.len() > MAX_SOURCE_BYTES {
        return Err(Failure::MalformedMessage);
    }
    open_mutation_source(&raw)?;
    Ok(raw)
}

pub(crate) fn open_staged_ids_mutation_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    local_source_sha256: &str,
    stage: &NativeIdsMutationSourceStage,
) -> Result<OpenedMutationSource, Failure> {
    let envelope = open_staged_mutation_source_envelope(
        storage_directory,
        account_fingerprint,
        local_source_sha256,
        stage,
    )?;
    open_mutation_source(&envelope)
}

pub(crate) fn verify_staged_ids_mutation_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    local_source_sha256: &str,
    msg: &MessageInst,
    stage: &NativeIdsMutationSourceStage,
) -> Result<OpenedMutationSource, Failure> {
    let envelope = open_staged_mutation_source_envelope(
        storage_directory,
        account_fingerprint,
        local_source_sha256,
        stage,
    )?;
    validate_mutation_source(&envelope, msg)?;
    open_mutation_source(&envelope)
}

fn validate_source_sha(value: &str) -> Result<(), Failure> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err(Failure::MalformedMessage);
    }
    Ok(())
}

fn validate_stage(stage: &NativeIdsMutationSourceStage) -> Result<(), Failure> {
    let reference = stage.protected_reference.strip_prefix("obcs2.ref.");
    let lease = stage.lease_reference.strip_prefix("obcs2.lease.");
    if !reference.is_some_and(|v| {
        v.len() == 43
            && v.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
    }) || !lease.is_some_and(|v| {
        v.len() == 32
            && v.bytes()
                .all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
    }) {
        return Err(Failure::MalformedMessage);
    }
    validate_source_sha(&stage.payload_sha256)?;
    if stage.payload_length == 0 || stage.payload_length > MAX_WRAPPER_BYTES as u64 {
        return Err(Failure::OversizedMessage);
    }
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_native_fetch::{
        cloud_sync_commit_protected_page_lease, cloud_sync_open_protected_ids_attachment_source,
        cloud_sync_stage_protected_ids_attachment_source,
    };
    use rustpush::{
        ConversationData, EditMessage, IndexedMessagePart, Message, MessagePart, MessageParts,
        UnsendMessage,
    };

    fn fixture(unsend: bool) -> MessageInst {
        let target = "5BC3779B-7898-4A15-A768-2EA04D3ABAA0".to_owned();
        MessageInst {
            id: "629802B8-9331-49C7-999A-69F057D8040C".to_owned(),
            sender: Some("mailto:test@example.invalid".to_owned()),
            conversation: Some(ConversationData {
                participants: vec!["tel:+15555550123".to_owned()],
                cv_name: None,
                sender_guid: None,
                after_guid: None,
            }),
            message: if unsend {
                Message::Unsend(UnsendMessage {
                    tuuid: target,
                    edit_part: 0,
                })
            } else {
                Message::Edit(EditMessage {
                    tuuid: target,
                    edit_part: 0,
                    new_parts: MessageParts(vec![IndexedMessagePart {
                        part: MessagePart::Text("replacement".to_owned(), Default::default()),
                        idx: Some(0),
                        ext: None,
                    }]),
                })
            },
            sent_timestamp: 1,
            send_delivered: false,
            target: None,
            verification_failed: false,
            certified_context: None,
        }
    }

    fn commit(path: &std::path::Path, stage: &NativeIdsMutationSourceStage) {
        cloud_sync_commit_protected_page_lease(
            path.to_path_buf(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_reference),
        )
        .unwrap();
    }

    #[test]
    fn mutation_source_requires_exact_commit_then_reopens_for_both_operations() {
        for unsend in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let account = "A".repeat(43);
            let source_hash = "a".repeat(64);
            let message = fixture(unsend);
            let stage = stage_ids_mutation_source(
                directory.path().to_path_buf(),
                account.clone(),
                &source_hash,
                &message,
            )
            .unwrap();
            assert_eq!(
                open_staged_ids_mutation_source(
                    directory.path().to_path_buf(),
                    account.clone(),
                    &source_hash,
                    &stage
                )
                .err()
                .unwrap(),
                Failure::ProtectedStorage
            );
            commit(directory.path(), &stage);
            commit(directory.path(), &stage); // exact lease commit is idempotent
            let recovered = verify_staged_ids_mutation_source(
                directory.path().to_path_buf(),
                account,
                &source_hash,
                &message,
                &stage,
            )
            .unwrap();
            assert_eq!(recovered.mutation_guid(), message.id);
            assert_ne!(recovered.mutation_guid(), recovered.target_guid());
            assert_eq!(
                encode_mutation_source(&recovered.message().unwrap()).unwrap(),
                encode_mutation_source(&message).unwrap()
            );
        }
    }

    #[test]
    fn mutation_source_rejects_changed_scope_binding_descriptor_and_request() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let account = "A".repeat(43);
        let sha = "a".repeat(64);
        let message = fixture(false);
        let stage =
            stage_ids_mutation_source(path.clone(), account.clone(), &sha, &message).unwrap();
        commit(directory.path(), &stage);
        assert_eq!(
            open_staged_ids_mutation_source(path.clone(), "B".repeat(43), &sha, &stage)
                .err()
                .unwrap(),
            Failure::ProtectedStorage
        );
        assert_eq!(
            open_staged_ids_mutation_source(path.clone(), account.clone(), &"b".repeat(64), &stage)
                .err()
                .unwrap(),
            Failure::BindingMismatch
        );
        let other =
            stage_ids_mutation_source(path.clone(), account.clone(), &sha, &fixture(true)).unwrap();
        commit(directory.path(), &other);
        for which in 0..6 {
            let mut changed = stage.clone();
            match which {
                0 => changed.payload_sha256 = "f".repeat(64),
                1 => changed.payload_length += 1,
                2 => changed.protected_reference = other.protected_reference.clone(),
                3 => changed.lease_reference = other.lease_reference.clone(),
                4 => changed.protected_reference = "not-a-reference".to_owned(),
                5 => changed.lease_reference = "obcs2.lease.../other".to_owned(),
                _ => unreachable!(),
            }
            assert!(
                open_staged_ids_mutation_source(path.clone(), account.clone(), &sha, &changed)
                    .is_err(),
                "descriptor {which}"
            );
        }
        assert_eq!(
            verify_staged_ids_mutation_source(path, account, &sha, &fixture(true), &stage)
                .err()
                .unwrap(),
            Failure::BindingMismatch
        );
    }

    #[test]
    fn mutation_source_cannot_be_relabelled_as_attachment_or_open_other_purpose() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let account = "A".repeat(43);
        let sha = "a".repeat(64);
        let stage = stage_ids_mutation_source(path.clone(), account.clone(), &sha, &fixture(false))
            .unwrap();
        commit(directory.path(), &stage);
        assert!(cloud_sync_open_protected_ids_attachment_source(
            path.clone(),
            account.clone(),
            &stage.protected_reference
        )
        .is_err());
        // Even correct wrapper bytes and an exact committed lease cannot cross purposes.
        let envelope = cloud_sync_open_protected_ids_mutation_source(
            path.clone(),
            account.clone(),
            &stage.protected_reference,
        )
        .unwrap();
        let attachment = cloud_sync_stage_protected_ids_attachment_source(
            path.clone(),
            account.clone(),
            envelope,
        )
        .unwrap();
        let relabelled = NativeIdsMutationSourceStage {
            protected_reference: attachment.protected_envelope_reference,
            lease_reference: attachment.lease_reference,
            ..stage
        };
        commit(directory.path(), &relabelled);
        assert_eq!(
            open_staged_ids_mutation_source(path, account, &sha, &relabelled)
                .err()
                .unwrap(),
            Failure::ProtectedStorage
        );
    }

    #[test]
    fn bad_descriptor_is_rejected_without_creating_storage() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("absent");
        let stage = NativeIdsMutationSourceStage {
            protected_reference: "obcs2.ref.../other".to_owned(),
            lease_reference: format!("obcs2.lease.{}", "a".repeat(32)),
            payload_sha256: "a".repeat(64),
            payload_length: 10,
        };
        assert_eq!(
            open_staged_ids_mutation_source(path.clone(), "A".repeat(43), &"a".repeat(64), &stage)
                .err()
                .unwrap(),
            Failure::MalformedMessage
        );
        assert!(!path.exists());
    }
}
