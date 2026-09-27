//! Purpose-preserving sources for shared read-only exact-record discovery.
//! Historical sources never become received sources or acquire IDS provenance.
//! This boundary only reopens committed local bytes and returns the exact GUID.

use std::path::PathBuf;

use crate::cloud_sync_historical_source::HistoricalBinding;
use crate::cloud_sync_historical_source_stage::{
    open_historical_archive_source, NativeHistoricalArchiveStage,
};
use crate::cloud_sync_outbound::CloudSyncOutboundFailure as Failure;
use crate::cloud_sync_received_source_stage::{
    open_received_archive_source, NativeReceivedArchiveStage,
};

pub(crate) enum ArchiveDiscoverySource {
    Received(NativeReceivedArchiveStage),
    Historical {
        snapshot_sha256: String,
        stage: NativeHistoricalArchiveStage,
    },
}

impl std::fmt::Debug for ArchiveDiscoverySource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ArchiveDiscoverySource(redacted)")
    }
}

impl ArchiveDiscoverySource {
    pub(crate) fn message_guid_hash(&self) -> &str {
        match self {
            Self::Received(stage) => &stage.message_guid_hash,
            Self::Historical { stage, .. } => &stage.message_guid_hash,
        }
    }

    pub(crate) fn source_sha256(&self) -> &str {
        match self {
            Self::Received(stage) => &stage.source_sha256,
            Self::Historical { stage, .. } => &stage.source_sha256,
        }
    }

    /// Rechecks the exact committed lease, encrypted purpose, integrity and
    /// origin binding every time the shared discovery flow crosses an await.
    /// Returning a GUID is neither a remote absence result nor create authority.
    pub(crate) fn open_guid(
        &self,
        directory: PathBuf,
        account_fingerprint: &str,
        protected_store_identity: &str,
    ) -> Result<String, Failure> {
        match self {
            Self::Received(stage) => {
                open_received_archive_source(directory, account_fingerprint.to_owned(), stage)
                    .map(|source| source.guid().to_owned())
            }
            Self::Historical {
                snapshot_sha256,
                stage,
            } => {
                let binding = HistoricalBinding {
                    snapshot_sha256,
                    account_fingerprint,
                    protected_store_identity,
                };
                open_historical_archive_source(directory, &binding, stage)
                    .map(|source| source.guid().to_owned())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_sync_historical_source::{HistoricalArchiveSource, HistoricalRow};
    use crate::cloud_sync_historical_source_stage::stage_historical_archive_source;
    use crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease;

    fn fixture(directory: &std::path::Path, sent: bool) -> (ArchiveDiscoverySource, String) {
        let identity = crate::cloud_sync_protector::protected_store_identity(
            directory.to_string_lossy().into_owned(),
        )
        .unwrap();
        let binding = HistoricalBinding {
            snapshot_sha256: &"a".repeat(64),
            account_fingerprint: &"A".repeat(43),
            protected_store_identity: &identity,
        };
        let source = HistoricalArchiveSource::capture(
            &HistoricalRow {
                guid: "exact-history-guid",
                text: "Synthetic history only",
                sender: if sent {
                    "mailto:owner@example.invalid"
                } else {
                    "mailto:peer@example.invalid"
                },
                peer: "peer@example.invalid",
                chat_guid: "iMessage;-;peer@example.invalid",
                date_created_ms: 1_700_000_000_123,
                is_from_me: sent,
            },
            &binding,
            sent,
        )
        .unwrap();
        let stage = stage_historical_archive_source(
            directory.to_path_buf(),
            &binding,
            &source.source_sha256().unwrap(),
            &source.encode().unwrap(),
        )
        .unwrap();
        (
            ArchiveDiscoverySource::Historical {
                snapshot_sha256: binding.snapshot_sha256.to_owned(),
                stage,
            },
            identity,
        )
    }

    fn commit(directory: &std::path::Path, source: &ArchiveDiscoverySource) {
        let ArchiveDiscoverySource::Historical { stage, .. } = source else {
            panic!()
        };
        cloud_sync_commit_protected_page_lease(
            directory.to_path_buf(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_reference),
        )
        .unwrap();
    }

    #[test]
    fn both_historical_origins_discover_only_after_exact_commit() {
        for sent in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let (source, identity) = fixture(directory.path(), sent);
            let open =
                || source.open_guid(directory.path().to_path_buf(), &"A".repeat(43), &identity);
            assert!(open().is_err());
            commit(directory.path(), &source);
            assert_eq!(open().unwrap(), "exact-history-guid");
            assert_eq!(source.message_guid_hash().len(), 64);
            assert_eq!(source.source_sha256().len(), 64);
            assert_eq!(format!("{source:?}"), "ArchiveDiscoverySource(redacted)");
        }
    }

    #[test]
    fn historical_discovery_rejects_changed_account_store_or_snapshot() {
        let directory = tempfile::tempdir().unwrap();
        let (mut source, identity) = fixture(directory.path(), false);
        commit(directory.path(), &source);
        assert!(source
            .open_guid(directory.path().to_path_buf(), &"B".repeat(43), &identity)
            .is_err());
        assert!(source
            .open_guid(
                directory.path().to_path_buf(),
                &"A".repeat(43),
                "wrong-store"
            )
            .is_err());
        let ArchiveDiscoverySource::Historical {
            snapshot_sha256, ..
        } = &mut source
        else {
            panic!()
        };
        *snapshot_sha256 = "b".repeat(64);
        assert!(source
            .open_guid(directory.path().to_path_buf(), &"A".repeat(43), &identity)
            .is_err());
    }

    #[test]
    fn historical_ciphertext_cannot_be_relabelled_as_received_discovery() {
        let directory = tempfile::tempdir().unwrap();
        let (source, identity) = fixture(directory.path(), false);
        commit(directory.path(), &source);
        let ArchiveDiscoverySource::Historical { stage, .. } = source else {
            panic!()
        };
        let relabelled = ArchiveDiscoverySource::Received(NativeReceivedArchiveStage {
            message_guid_hash: stage.message_guid_hash,
            source_sha256: stage.source_sha256,
            protected_reference: stage.protected_reference,
            lease_reference: stage.lease_reference,
            payload_sha256: stage.payload_sha256,
            payload_length: stage.payload_length,
        });
        assert!(relabelled
            .open_guid(directory.path().to_path_buf(), &"A".repeat(43), &identity)
            .is_err());
    }

    #[test]
    fn existing_incoming_and_mirrored_discovery_keep_their_received_purpose() {
        for mirrored in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let (message, handles) = crate::cloud_sync_received_source::tests::fixture(
                mirrored,
                "Synthetic received compatibility",
            );
            let stage = crate::cloud_sync_received_source_stage::stage_received_archive_source(
                directory.path().to_path_buf(),
                "A".repeat(43),
                &message,
                &handles,
            )
            .unwrap();
            cloud_sync_commit_protected_page_lease(
                directory.path().to_path_buf(),
                &stage.lease_reference,
                std::slice::from_ref(&stage.protected_reference),
            )
            .unwrap();
            let source = ArchiveDiscoverySource::Received(stage.clone());
            assert_eq!(
                source
                    .open_guid(
                        directory.path().to_path_buf(),
                        &"A".repeat(43),
                        "current-store",
                    )
                    .unwrap(),
                message.id
            );
            assert!(source
                .open_guid(
                    directory.path().to_path_buf(),
                    &"B".repeat(43),
                    "current-store",
                )
                .is_err());
            let identity = crate::cloud_sync_protector::protected_store_identity(
                directory.path().to_string_lossy().into_owned(),
            )
            .unwrap();
            let relabelled = ArchiveDiscoverySource::Historical {
                snapshot_sha256: "a".repeat(64),
                stage: NativeHistoricalArchiveStage {
                    message_guid_hash: stage.message_guid_hash,
                    source_sha256: stage.source_sha256,
                    protected_reference: stage.protected_reference,
                    lease_reference: stage.lease_reference,
                    payload_sha256: stage.payload_sha256,
                    payload_length: stage.payload_length,
                },
            };
            assert!(relabelled
                .open_guid(directory.path().to_path_buf(), &"A".repeat(43), &identity,)
                .is_err());
        }
    }
}
