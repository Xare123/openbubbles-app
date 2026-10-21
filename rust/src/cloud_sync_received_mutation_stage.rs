//! Inline encrypted received mutation retention. No file lease or remote write.
//! A distinct protector domain prevents promotion to an original receive or
//! outgoing IDS receipt. ObjectBox owns the ciphertext before worker admission.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use crate::cloud_sync_received_mutation_source::ReceivedMutationSource;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rustpush::MessageInst;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const MAX_BYTES: usize = 1024 * 1024;
const ROLE: &str = "idsReceivedMutationSource";

pub(crate) struct NativeReceivedMutationSeed {
    pub(crate) mutation_guid_hash: String,
    pub(crate) source_sha256: String,
    pub(crate) ciphertext: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Seed {
    domain: String,
    version: u32,
    protected_store_identity: String,
    source_b64: String,
}

pub(crate) fn seal_received_mutation_seed(
    directory: PathBuf,
    account: String,
    expected_store: &str,
    wire: &MessageInst,
    local_handles: &[String],
) -> Result<NativeReceivedMutationSeed, Failure> {
    let source = ReceivedMutationSource::capture(wire, local_handles)?;
    let path = directory.to_string_lossy().into_owned();
    if crate::cloud_sync_protector::protected_store_identity(path.clone())
        .map_err(|_| Failure::ProtectedStorage)?
        != expected_store
    {
        return Err(Failure::BindingMismatch);
    }
    let wrapper = Seed {
        domain: "cloud-sync-received-mutation-retry-seed".into(),
        version: 1,
        protected_store_identity: expected_store.into(),
        source_b64: URL_SAFE_NO_PAD.encode(source.encode()?),
    };
    let bytes = serde_json::to_string(&wrapper).map_err(|_| Failure::MalformedMessage)?;
    if bytes.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let ciphertext = crate::cloud_sync_protector::protect(
        path,
        account,
        "com.apple.messages.cloud".into(),
        "private".into(),
        "messageManateeZone".into(),
        "messages".into(),
        2,
        ROLE.into(),
        bytes,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if ciphertext.len() > 2 * MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    Ok(NativeReceivedMutationSeed {
        mutation_guid_hash: source.guid_hash()?,
        source_sha256: source.source_sha256()?,
        ciphertext,
    })
}

pub(crate) fn open_received_mutation_seed(
    directory: PathBuf,
    account: String,
    expected_store: &str,
    seed: &NativeReceivedMutationSeed,
) -> Result<ReceivedMutationSource, Failure> {
    if seed.ciphertext.is_empty() || seed.ciphertext.len() > 2 * MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let path = directory.to_string_lossy().into_owned();
    if crate::cloud_sync_protector::protected_store_identity(path.clone())
        .map_err(|_| Failure::ProtectedStorage)?
        != expected_store
    {
        return Err(Failure::BindingMismatch);
    }
    let plaintext = crate::cloud_sync_protector::unprotect(
        path,
        account,
        "com.apple.messages.cloud".into(),
        "private".into(),
        "messageManateeZone".into(),
        "messages".into(),
        2,
        ROLE.into(),
        seed.ciphertext.clone(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if plaintext.len() > MAX_BYTES {
        return Err(Failure::OversizedMessage);
    }
    let wrapper: Seed = serde_json::from_str(&plaintext).map_err(|_| Failure::MalformedMessage)?;
    if wrapper.domain != "cloud-sync-received-mutation-retry-seed"
        || wrapper.version != 1
        || wrapper.protected_store_identity != expected_store
        || serde_json::to_string(&wrapper).map_err(|_| Failure::MalformedMessage)? != plaintext
    {
        return Err(Failure::BindingMismatch);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(&wrapper.source_b64)
        .map_err(|_| Failure::MalformedMessage)?;
    if URL_SAFE_NO_PAD.encode(&bytes) != wrapper.source_b64 {
        return Err(Failure::MalformedMessage);
    }
    let source = ReceivedMutationSource::decode(&bytes)?;
    if source.guid_hash()? != seed.mutation_guid_hash
        || source.source_sha256()? != seed.source_sha256
    {
        return Err(Failure::BindingMismatch);
    }
    Ok(source)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn received_mutation_seed_reopens_exact_source_without_original_or_outgoing_authority() {
        for mirrored in [false, true] {
            for unsend in [false, true] {
                let directory = tempfile::tempdir().unwrap();
                let path = directory.path().to_path_buf();
                let identity = crate::cloud_sync_protector::protected_store_identity(
                    path.to_string_lossy().into_owned(),
                )
                .unwrap();
                let (wire, handles) =
                    crate::cloud_sync_received_mutation_source::tests::fixture(mirrored, unsend);
                let seed = seal_received_mutation_seed(
                    path.clone(),
                    "A".repeat(43),
                    &identity,
                    &wire,
                    &handles,
                )
                .unwrap();
                assert!(!seed.ciphertext.contains("Edited"));
                assert!(!seed.ciphertext.contains("example.com"));
                let reopened =
                    open_received_mutation_seed(path.clone(), "A".repeat(43), &identity, &seed)
                        .unwrap();
                assert_eq!(reopened.guid(), wire.id);
                assert_eq!(reopened.source_sha256().unwrap(), seed.source_sha256);
                assert!(open_received_mutation_seed(
                    path.clone(),
                    "B".repeat(43),
                    &identity,
                    &seed
                )
                .is_err());
                assert!(open_received_mutation_seed(
                    path.clone(),
                    "A".repeat(43),
                    "another-store",
                    &seed
                )
                .is_err());
                let wrong_role =
                    crate::cloud_sync_received_source_stage::NativeReceivedArchiveSeed {
                        message_guid_hash: seed.mutation_guid_hash.clone(),
                        source_sha256: seed.source_sha256.clone(),
                        ciphertext: seed.ciphertext.clone(),
                    };
                assert!(
                    crate::cloud_sync_received_source_stage::stage_received_archive_seed(
                        path.clone(),
                        "A".repeat(43),
                        &identity,
                        &wrong_role
                    )
                    .is_err()
                );
                let swapped = NativeReceivedMutationSeed {
                    mutation_guid_hash: "b".repeat(64),
                    source_sha256: seed.source_sha256.clone(),
                    ciphertext: seed.ciphertext.clone(),
                };
                assert!(
                    open_received_mutation_seed(path, "A".repeat(43), &identity, &swapped).is_err()
                );
            }
        }
    }
}
