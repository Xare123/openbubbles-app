//! Local-only protection for immutable received-message sources. This does not
//! warm CloudKit dependencies, send IDS, create records, or authorize uploads.
//! The caller must durably adopt the descriptor before committing its lease.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_native_fetch::{
    cloud_sync_open_protected_received_archive_source,
    cloud_sync_stage_protected_received_archive_source, cloud_sync_verify_committed_lease_exact,
};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use crate::cloud_sync_received_source::{hex_digest, ReceivedArchiveSource};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rustpush::MessageInst;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const MAX_BYTES: usize = 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReceivedStageV1 {
    version: u32,
    guid_hash: String,
    source_sha256: String,
    source_b64: String,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct NativeReceivedArchiveStage {
    pub(crate) message_guid_hash: String,
    pub(crate) source_sha256: String,
    pub(crate) protected_reference: String,
    pub(crate) lease_reference: String,
    pub(crate) payload_sha256: String,
    pub(crate) payload_length: u64,
}

pub(crate) fn stage_received_archive_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    message: &MessageInst,
    observed_local_handles: &[String],
) -> Result<NativeReceivedArchiveStage, Failure> {
    let source = ReceivedArchiveSource::capture(message, observed_local_handles)?;
    stage_captured_source(storage_directory, account_fingerprint, &source)
}

fn stage_captured_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    source: &ReceivedArchiveSource,
) -> Result<NativeReceivedArchiveStage, Failure> {
    let wrapper = ReceivedStageV1 {
        version: 1,
        guid_hash: source.guid_hash()?,
        source_sha256: source.source_sha256()?,
        source_b64: URL_SAFE_NO_PAD.encode(source.encode()?),
    };
    let bytes = serde_json::to_vec(&wrapper).map_err(|_| Failure::MalformedMessage)?;
    if bytes.is_empty() || bytes.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let staged = cloud_sync_stage_protected_received_archive_source(
        storage_directory,
        account_fingerprint,
        URL_SAFE_NO_PAD.encode(&bytes),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    Ok(NativeReceivedArchiveStage {
        message_guid_hash: wrapper.guid_hash,
        source_sha256: wrapper.source_sha256,
        protected_reference: staged.protected_envelope_reference,
        lease_reference: staged.lease_reference,
        payload_sha256: hex_digest(&bytes),
        payload_length: bytes.len() as u64,
    })
}

/// Encrypted retry seed stored atomically alongside the Message in ObjectBox.
/// No file lease exists yet, so recovery cannot remove it between receipt and
/// adoption. Contains no key or plaintext at the bridge boundary.
pub(crate) struct NativeReceivedArchiveSeed {
    pub(crate) message_guid_hash: String,
    pub(crate) source_sha256: String,
    pub(crate) ciphertext: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReceivedSeedV1 {
    domain: String,
    version: u32,
    protected_store_identity: String,
    source_b64: String,
}

pub(crate) fn seal_received_archive_seed(
    storage_directory: PathBuf,
    account_fingerprint: String,
    expected_store: &str,
    message: &MessageInst,
    observed_local_handles: &[String],
) -> Result<NativeReceivedArchiveSeed, Failure> {
    let source = ReceivedArchiveSource::capture(message, observed_local_handles)?;
    let path = storage_directory.to_string_lossy().into_owned();
    if crate::cloud_sync_protector::protected_store_identity(path.clone())
        .map_err(|_| Failure::ProtectedStorage)?
        != expected_store
    {
        return Err(Failure::BindingMismatch);
    }
    let seed = ReceivedSeedV1 {
        domain: "cloud-sync-received-retry-seed".into(),
        version: 1,
        protected_store_identity: expected_store.into(),
        source_b64: URL_SAFE_NO_PAD.encode(source.encode()?),
    };
    let plaintext = serde_json::to_string(&seed).map_err(|_| Failure::MalformedMessage)?;
    if plaintext.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let ciphertext = crate::cloud_sync_protector::protect(
        path,
        account_fingerprint,
        "com.apple.messages.cloud".into(),
        "private".into(),
        "messageManateeZone".into(),
        "messages".into(),
        2,
        "idsReceivedArchiveSource".into(),
        plaintext,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if ciphertext.len() > 2 * MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(NativeReceivedArchiveSeed {
        message_guid_hash: source.guid_hash()?,
        source_sha256: source.source_sha256()?,
        ciphertext,
    })
}

/// Reconstitutes ONLY the authenticated original receive, never current UI
/// text or a synthesized IDS send. Safe to call after process restart with
/// the same account/store. Caller must journal-adopt then commit the lease.
pub(crate) fn stage_received_archive_seed(
    storage_directory: PathBuf,
    account_fingerprint: String,
    expected_store: &str,
    seed: &NativeReceivedArchiveSeed,
) -> Result<NativeReceivedArchiveStage, Failure> {
    if seed.ciphertext.is_empty() || seed.ciphertext.len() > 2 * MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let path = storage_directory.to_string_lossy().into_owned();
    if crate::cloud_sync_protector::protected_store_identity(path.clone())
        .map_err(|_| Failure::ProtectedStorage)?
        != expected_store
    {
        return Err(Failure::BindingMismatch);
    }
    let plaintext = crate::cloud_sync_protector::unprotect(
        path,
        account_fingerprint.clone(),
        "com.apple.messages.cloud".into(),
        "private".into(),
        "messageManateeZone".into(),
        "messages".into(),
        2,
        "idsReceivedArchiveSource".into(),
        seed.ciphertext.clone(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if plaintext.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let decoded: ReceivedSeedV1 =
        serde_json::from_str(&plaintext).map_err(|_| Failure::MalformedMessage)?;
    if decoded.domain != "cloud-sync-received-retry-seed"
        || decoded.version != 1
        || decoded.protected_store_identity != expected_store
        || serde_json::to_string(&decoded).map_err(|_| Failure::MalformedMessage)? != plaintext
    {
        return Err(Failure::BindingMismatch);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(&decoded.source_b64)
        .map_err(|_| Failure::MalformedMessage)?;
    if URL_SAFE_NO_PAD.encode(&bytes) != decoded.source_b64 {
        return Err(Failure::MalformedMessage);
    }
    let source = ReceivedArchiveSource::decode(&bytes)?;
    if source.guid_hash()? != seed.message_guid_hash
        || source.source_sha256()? != seed.source_sha256
    {
        return Err(Failure::BindingMismatch);
    }
    stage_captured_source(storage_directory, account_fingerprint, &source)
}

pub(crate) fn open_received_archive_source(
    storage_directory: PathBuf,
    account_fingerprint: String,
    stage: &NativeReceivedArchiveStage,
) -> Result<ReceivedArchiveSource, Failure> {
    validate_stage(stage)?;
    cloud_sync_verify_committed_lease_exact(
        storage_directory.clone(),
        &stage.lease_reference,
        std::slice::from_ref(&stage.protected_reference),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let value = cloud_sync_open_protected_received_archive_source(
        storage_directory,
        account_fingerprint,
        &stage.protected_reference,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if value.len() > MAX_BYTES.div_ceil(3) * 4 {
        return Err(Failure::OversizedMessage);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(&value)
        .map_err(|_| Failure::MalformedMessage)?;
    if bytes.len() as u64 != stage.payload_length
        || hex_digest(&bytes) != stage.payload_sha256
        || URL_SAFE_NO_PAD.encode(&bytes) != value
    {
        return Err(Failure::BindingMismatch);
    }
    let wrapper: ReceivedStageV1 =
        serde_json::from_slice(&bytes).map_err(|_| Failure::MalformedMessage)?;
    if wrapper.version != 1
        || serde_json::to_vec(&wrapper).map_err(|_| Failure::MalformedMessage)? != bytes
    {
        return Err(Failure::MalformedMessage);
    }
    if wrapper.guid_hash != stage.message_guid_hash || wrapper.source_sha256 != stage.source_sha256
    {
        return Err(Failure::BindingMismatch);
    }
    let source_bytes = URL_SAFE_NO_PAD
        .decode(&wrapper.source_b64)
        .map_err(|_| Failure::MalformedMessage)?;
    if URL_SAFE_NO_PAD.encode(&source_bytes) != wrapper.source_b64 {
        return Err(Failure::MalformedMessage);
    }
    let source = ReceivedArchiveSource::decode(&source_bytes)?;
    if source.guid_hash()? != stage.message_guid_hash
        || source.source_sha256()? != stage.source_sha256
    {
        return Err(Failure::BindingMismatch);
    }
    Ok(source)
}

fn validate_stage(stage: &NativeReceivedArchiveStage) -> Result<(), Failure> {
    fn digest(s: &str) -> bool {
        s.len() == 64
            && s.bytes()
                .all(|c| c.is_ascii_digit() || matches!(c, b'a'..=b'f'))
    }
    let reference = stage.protected_reference.strip_prefix("obcs2.ref.");
    let lease = stage.lease_reference.strip_prefix("obcs2.lease.");
    if !digest(&stage.message_guid_hash)
        || !digest(&stage.source_sha256)
        || !digest(&stage.payload_sha256)
        || !reference.is_some_and(|s| {
            s.len() == 43
                && s.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-'))
        })
        || !lease.is_some_and(|s| {
            s.len() == 32
                && s.bytes()
                    .all(|c| c.is_ascii_digit() || matches!(c, b'a'..=b'f'))
        })
    {
        return Err(Failure::MalformedMessage);
    }
    if stage.payload_length == 0 || stage.payload_length > MAX_BYTES as u64 {
        return Err(Failure::OversizedMessage);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_native_fetch::{
        cloud_sync_commit_protected_page_lease, cloud_sync_open_protected_ids_attachment_source,
        cloud_sync_open_protected_ids_mutation_source, cloud_sync_open_protected_outbound_message,
    };
    use crate::cloud_sync_received_source::tests::fixture;

    #[test]
    fn sealed_retry_seed_survives_cleanup_and_preserves_original_source() {
        for mirrored in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().to_path_buf();
            let identity = crate::cloud_sync_protector::protected_store_identity(
                path.to_string_lossy().into_owned(),
            )
            .unwrap();
            let (wire, handles) = fixture(mirrored, "retry original 😀 text");
            let seed = seal_received_archive_seed(
                path.clone(),
                "A".repeat(43),
                &identity,
                &wire,
                &handles,
            )
            .unwrap();
            assert!(!seed.ciphertext.contains("retry original"));
            assert!(!seed.ciphertext.contains("owner@example.com"));
            // No stage file or handoff lease exists yet. Repeated sealing uses
            // randomized encryption but preserves the immutable source digest.
            let again = seal_received_archive_seed(
                path.clone(),
                "A".repeat(43),
                &identity,
                &wire,
                &handles,
            )
            .unwrap();
            assert_eq!(again.source_sha256, seed.source_sha256);
            assert_ne!(again.ciphertext, seed.ciphertext);
            let stage = stage_received_archive_seed(path.clone(), "A".repeat(43), &identity, &seed)
                .unwrap();
            cloud_sync_commit_protected_page_lease(
                path.clone(),
                &stage.lease_reference,
                std::slice::from_ref(&stage.protected_reference),
            )
            .unwrap();
            let opened = open_received_archive_source(path, "A".repeat(43), &stage).unwrap();
            assert_eq!(opened.guid(), wire.id);
            assert_eq!(opened.text(), "retry original 😀 text");
            assert_eq!(opened.source_sha256().unwrap(), seed.source_sha256);
        }
    }

    #[test]
    fn seed_refuses_account_store_ciphertext_and_descriptor_substitution() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_path_buf();
        let identity = crate::cloud_sync_protector::protected_store_identity(
            path.to_string_lossy().into_owned(),
        )
        .unwrap();
        let (wire, handles) = fixture(false, "seed test");
        let seed =
            seal_received_archive_seed(path.clone(), "A".repeat(43), &identity, &wire, &handles)
                .unwrap();
        assert!(
            stage_received_archive_seed(path.clone(), "B".repeat(43), &identity, &seed).is_err()
        );
        assert!(
            stage_received_archive_seed(path.clone(), "A".repeat(43), "wrong-store", &seed)
                .is_err()
        );
        for field in 0..3 {
            let altered = NativeReceivedArchiveSeed {
                message_guid_hash: if field == 0 {
                    "f".repeat(64)
                } else {
                    seed.message_guid_hash.clone()
                },
                source_sha256: if field == 1 {
                    "e".repeat(64)
                } else {
                    seed.source_sha256.clone()
                },
                ciphertext: if field == 2 {
                    format!("{}x", seed.ciphertext)
                } else {
                    seed.ciphertext.clone()
                },
            };
            assert!(
                stage_received_archive_seed(path.clone(), "A".repeat(43), &identity, &altered)
                    .is_err()
            );
        }
        let other = tempfile::tempdir().unwrap();
        assert!(stage_received_archive_seed(
            other.path().to_path_buf(),
            "A".repeat(43),
            &identity,
            &seed
        )
        .is_err());
    }

    #[test]
    fn exact_commit_is_required_and_reopen_preserves_both_origins() {
        for mirrored in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().to_path_buf();
            let (message, handles) = fixture(mirrored, "synthetic received text");
            let stage =
                stage_received_archive_source(path.clone(), "A".repeat(43), &message, &handles)
                    .unwrap();
            assert!(matches!(
                open_received_archive_source(path.clone(), "A".repeat(43), &stage),
                Err(Failure::ProtectedStorage)
            ));
            for _ in 0..2 {
                cloud_sync_commit_protected_page_lease(
                    path.clone(),
                    &stage.lease_reference,
                    std::slice::from_ref(&stage.protected_reference),
                )
                .unwrap();
            }
            let opened =
                open_received_archive_source(path.clone(), "A".repeat(43), &stage).unwrap();
            assert_eq!(opened.guid(), message.id);
            assert_eq!(opened.text(), "synthetic received text");
            assert_eq!(opened.recipient(), "mailto:owner@example.com");
            assert_eq!(opened.guid_hash().unwrap(), stage.message_guid_hash);
            assert_eq!(opened.source_sha256().unwrap(), stage.source_sha256);
            // Wrong account and wrong protected purpose cannot relabel a source
            // as a sent attachment, outgoing mutation or outgoing message.
            assert!(open_received_archive_source(path.clone(), "B".repeat(43), &stage).is_err());
            assert!(cloud_sync_open_protected_ids_mutation_source(
                path.clone(),
                "A".repeat(43),
                &stage.protected_reference
            )
            .is_err());
            assert!(cloud_sync_open_protected_ids_attachment_source(
                path.clone(),
                "A".repeat(43),
                &stage.protected_reference
            )
            .is_err());
            assert!(cloud_sync_open_protected_outbound_message(
                path,
                "A".repeat(43),
                &stage.protected_reference
            )
            .is_err());
        }
    }

    #[test]
    fn every_descriptor_field_remains_bound_without_creating_another_source() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().to_path_buf();
        let (message, handles) = fixture(false, "synthetic");
        let stage = stage_received_archive_source(path.clone(), "A".repeat(43), &message, &handles)
            .unwrap();
        cloud_sync_commit_protected_page_lease(
            path.clone(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_reference),
        )
        .unwrap();
        for change in 0..6 {
            let mut tampered = stage.clone();
            match change {
                0 => tampered.message_guid_hash = "a".repeat(64),
                1 => tampered.source_sha256 = "b".repeat(64),
                2 => tampered.payload_sha256 = "c".repeat(64),
                3 => tampered.payload_length += 1,
                4 => tampered.protected_reference = format!("obcs2.ref.{}", "Z".repeat(43)),
                _ => tampered.lease_reference = format!("obcs2.lease.{}", "d".repeat(32)),
            }
            assert!(open_received_archive_source(path.clone(), "A".repeat(43), &tampered).is_err());
        }
        assert!(open_received_archive_source(path, "A".repeat(43), &stage).is_ok());
    }
}
