//! Local protection for qualified historical sources, not a live receive or
//! IDS-send receipt. The caller owns snapshot/account qualification, exclusion
//! against local maintenance, durable adoption, and exact lease commitment.
//! No CloudKit request, source reconstruction, or automatic upload occurs here.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_historical_source::{HistoricalArchiveSource, HistoricalBinding};
use crate::cloud_sync_native_fetch::{
    cloud_sync_open_protected_historical_archive_source,
    cloud_sync_stage_protected_historical_archive_source, cloud_sync_verify_committed_lease_exact,
};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const MAX_BYTES: usize = 1024 * 1024;

/// Metadata only. It becomes durable ownership only when its caller adopts it
/// atomically and commits its exact lease. No Debug implementation leaks refs.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct NativeHistoricalArchiveStage {
    pub(crate) message_guid_hash: String,
    pub(crate) source_sha256: String,
    pub(crate) protected_reference: String,
    pub(crate) lease_reference: String,
    pub(crate) payload_sha256: String,
    pub(crate) payload_length: u64,
}

/// Validate canonical Dart bytes and their independently assessed source digest
/// before protecting them in the current store. The bound store must be this
/// actual installation, not merely a syntactically valid caller string.
pub(crate) fn stage_historical_archive_source(
    storage_directory: PathBuf,
    binding: &HistoricalBinding,
    expected_source_sha256: &str,
    source_bytes: &[u8],
) -> Result<NativeHistoricalArchiveStage, Failure> {
    let source = HistoricalArchiveSource::decode(source_bytes, binding, expected_source_sha256)?;
    require_store(&storage_directory, binding)?;
    let staged = cloud_sync_stage_protected_historical_archive_source(
        storage_directory,
        binding.account_fingerprint.to_owned(),
        URL_SAFE_NO_PAD.encode(source_bytes),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    Ok(NativeHistoricalArchiveStage {
        message_guid_hash: source.guid_hash()?,
        source_sha256: source.source_sha256()?,
        protected_reference: staged.protected_envelope_reference,
        lease_reference: staged.lease_reference,
        payload_sha256: digest(source_bytes),
        payload_length: source_bytes.len() as u64,
    })
}

/// Reopen only an exactly committed historical lease in its original account,
/// installation and source snapshot. This is source integrity, not authority to
/// create a remote record or evidence that it is absent from iCloud.
pub(crate) fn open_historical_archive_source(
    storage_directory: PathBuf,
    binding: &HistoricalBinding,
    stage: &NativeHistoricalArchiveStage,
) -> Result<HistoricalArchiveSource, Failure> {
    validate_stage(stage)?;
    require_store(&storage_directory, binding)?;
    cloud_sync_verify_committed_lease_exact(
        storage_directory.clone(),
        &stage.lease_reference,
        std::slice::from_ref(&stage.protected_reference),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    let encoded = cloud_sync_open_protected_historical_archive_source(
        storage_directory,
        binding.account_fingerprint.to_owned(),
        &stage.protected_reference,
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if encoded.len() > MAX_BYTES.div_ceil(3) * 4 {
        return Err(Failure::OversizedMessage);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(&encoded)
        .map_err(|_| Failure::MalformedMessage)?;
    if bytes.len() as u64 != stage.payload_length
        || digest(&bytes) != stage.payload_sha256
        || URL_SAFE_NO_PAD.encode(&bytes) != encoded
    {
        return Err(Failure::BindingMismatch);
    }
    let source = HistoricalArchiveSource::decode(&bytes, binding, &stage.source_sha256)?;
    if source.guid_hash()? != stage.message_guid_hash {
        return Err(Failure::BindingMismatch);
    }
    Ok(source)
}

fn require_store(directory: &Path, binding: &HistoricalBinding) -> Result<(), Failure> {
    let actual = crate::cloud_sync_protector::protected_store_identity(
        directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| Failure::ProtectedStorage)?;
    if actual != binding.protected_store_identity {
        return Err(Failure::BindingMismatch);
    }
    Ok(())
}

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn validate_stage(stage: &NativeHistoricalArchiveStage) -> Result<(), Failure> {
    let valid_hash = |s: &str| {
        s.len() == 64
            && s.bytes()
                .all(|c| c.is_ascii_digit() || matches!(c, b'a'..=b'f'))
    };
    let reference = stage.protected_reference.strip_prefix("obcs2.ref.");
    let lease = stage.lease_reference.strip_prefix("obcs2.lease.");
    if !valid_hash(&stage.message_guid_hash)
        || !valid_hash(&stage.source_sha256)
        || !valid_hash(&stage.payload_sha256)
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
    use crate::cloud_sync_historical_source::{HistoricalArchiveOrigin, HistoricalRow};
    use crate::cloud_sync_native_fetch::{
        cloud_sync_commit_protected_page_lease, cloud_sync_open_protected_ids_mutation_source,
        cloud_sync_open_protected_outbound_message,
        cloud_sync_open_protected_received_archive_source,
        cloud_sync_rollback_protected_page_lease,
    };

    const SNAPSHOT: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const ACCOUNT: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    fn store_identity(directory: &Path) -> String {
        crate::cloud_sync_protector::protected_store_identity(
            directory.to_string_lossy().into_owned(),
        )
        .unwrap()
    }

    fn binding(identity: &str) -> HistoricalBinding<'_> {
        HistoricalBinding {
            snapshot_sha256: SNAPSHOT,
            account_fingerprint: ACCOUNT,
            protected_store_identity: identity,
        }
    }

    fn source(binding: &HistoricalBinding, sent: bool) -> HistoricalArchiveSource {
        HistoricalArchiveSource::capture(
            &HistoricalRow {
                guid: "historical-fixture-guid",
                text: "Historical fixture 😀 only",
                sender: if sent {
                    "mailto:owner@example.com"
                } else {
                    "mailto:peer@example.com"
                },
                peer: "peer@example.com",
                chat_guid: "iMessage;-;peer@example.com",
                date_created_ms: 1_700_000_000_123,
                is_from_me: sent,
            },
            binding,
            sent,
        )
        .unwrap()
    }

    fn stage(path: &Path, binding: &HistoricalBinding, sent: bool) -> NativeHistoricalArchiveStage {
        let source = source(binding, sent);
        stage_historical_archive_source(
            path.to_path_buf(),
            binding,
            &source.source_sha256().unwrap(),
            &source.encode().unwrap(),
        )
        .unwrap()
    }

    fn commit(path: &Path, stage: &NativeHistoricalArchiveStage) {
        cloud_sync_commit_protected_page_lease(
            path.to_path_buf(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_reference),
        )
        .unwrap();
    }

    #[test]
    fn exact_commit_and_reopen_preserve_both_historical_origins() {
        for sent in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let identity = store_identity(directory.path());
            let binding = binding(&identity);
            let staged = stage(directory.path(), &binding, sent);
            assert!(open_historical_archive_source(
                directory.path().to_path_buf(),
                &binding,
                &staged
            )
            .is_err());
            commit(directory.path(), &staged);
            commit(directory.path(), &staged);
            let reopened =
                open_historical_archive_source(directory.path().to_path_buf(), &binding, &staged)
                    .unwrap();
            assert_eq!(
                reopened.encode().unwrap(),
                source(&binding, sent).encode().unwrap()
            );
            assert!(
                reopened.origin()
                    == if sent {
                        HistoricalArchiveOrigin::HistoricalSent
                    } else {
                        HistoricalArchiveOrigin::HistoricalReceived
                    }
            );
        }
    }

    #[test]
    fn snapshot_account_installation_and_expected_digest_cannot_be_substituted() {
        let directory = tempfile::tempdir().unwrap();
        let identity = store_identity(directory.path());
        let valid = binding(&identity);
        let original = source(&valid, false);
        let bytes = original.encode().unwrap();
        let hash = original.source_sha256().unwrap();
        let staged = stage(directory.path(), &valid, false);
        commit(directory.path(), &staged);
        for wrong in [
            HistoricalBinding {
                snapshot_sha256: &"b".repeat(64),
                ..binding(&identity)
            },
            HistoricalBinding {
                account_fingerprint: &"B".repeat(43),
                ..binding(&identity)
            },
            HistoricalBinding {
                protected_store_identity: "wrong-store",
                ..binding(&identity)
            },
        ] {
            assert!(stage_historical_archive_source(
                directory.path().to_path_buf(),
                &wrong,
                &hash,
                &bytes
            )
            .is_err());
            assert!(open_historical_archive_source(
                directory.path().to_path_buf(),
                &wrong,
                &staged
            )
            .is_err());
        }
        let other = tempfile::tempdir().unwrap();
        assert!(
            stage_historical_archive_source(other.path().to_path_buf(), &valid, &hash, &bytes)
                .is_err()
        );
        assert!(
            open_historical_archive_source(other.path().to_path_buf(), &valid, &staged).is_err()
        );
        assert!(stage_historical_archive_source(
            directory.path().to_path_buf(),
            &valid,
            &"c".repeat(64),
            &bytes
        )
        .is_err());
    }

    #[test]
    fn descriptor_changes_cannot_open_another_committed_source() {
        let directory = tempfile::tempdir().unwrap();
        let identity = store_identity(directory.path());
        let binding = binding(&identity);
        let staged = stage(directory.path(), &binding, true);
        commit(directory.path(), &staged);
        for field in 0..6 {
            let mut changed = staged.clone();
            match field {
                0 => changed.message_guid_hash = "a".repeat(64),
                1 => changed.source_sha256 = "b".repeat(64),
                2 => changed.payload_sha256 = "c".repeat(64),
                3 => changed.payload_length += 1,
                4 => changed.protected_reference = format!("obcs2.ref.{}", "Z".repeat(43)),
                _ => changed.lease_reference = format!("obcs2.lease.{}", "d".repeat(32)),
            }
            assert!(open_historical_archive_source(
                directory.path().to_path_buf(),
                &binding,
                &changed
            )
            .is_err());
        }
        assert!(
            open_historical_archive_source(directory.path().to_path_buf(), &binding, &staged)
                .is_ok()
        );
    }

    #[test]
    fn historical_source_cannot_be_opened_as_live_receive_send_or_mutation() {
        let directory = tempfile::tempdir().unwrap();
        let identity = store_identity(directory.path());
        let binding = binding(&identity);
        let staged = stage(directory.path(), &binding, false);
        commit(directory.path(), &staged);
        for open in [
            cloud_sync_open_protected_received_archive_source,
            cloud_sync_open_protected_outbound_message,
            cloud_sync_open_protected_ids_mutation_source,
        ] {
            assert!(open(
                directory.path().to_path_buf(),
                ACCOUNT.into(),
                &staged.protected_reference
            )
            .is_err());
        }
    }

    #[test]
    fn unadopted_stage_can_be_rolled_back_without_affecting_owned_source() {
        let directory = tempfile::tempdir().unwrap();
        let identity = store_identity(directory.path());
        let binding = binding(&identity);
        let owned = stage(directory.path(), &binding, false);
        commit(directory.path(), &owned);
        let unadopted = stage(directory.path(), &binding, false);
        cloud_sync_rollback_protected_page_lease(
            directory.path().to_path_buf(),
            &unadopted.lease_reference,
        )
        .unwrap();
        assert!(open_historical_archive_source(
            directory.path().to_path_buf(),
            &binding,
            &unadopted
        )
        .is_err());
        assert!(
            open_historical_archive_source(directory.path().to_path_buf(), &binding, &owned)
                .is_ok()
        );
    }
}
