//! Real local protector/adoption tests for the shared staging implementation.
//! Identity callbacks are synthetic; no Apple authentication or upload is claimed.
use super::*;
use crate::cloud_sync_historical_source::{
    HistoricalArchiveSource, HistoricalBinding, HistoricalRow,
};
use crate::cloud_sync_historical_source_stage::{
    open_historical_archive_source, NativeHistoricalArchiveStage,
};
use crate::cloud_sync_native_fetch::{
    cloud_sync_commit_protected_page_lease, cloud_sync_recover_abandoned_page_leases,
};
use std::cell::Cell;

const SNAPSHOT: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn metadata(directory: &str) -> CloudSyncNativeAuthMetadata {
    CloudSyncNativeAuthMetadata {
        account_fingerprint: "A".repeat(43),
        protected_store_identity: crate::cloud_sync_protector::protected_store_identity(
            directory.to_owned(),
        )
        .unwrap(),
        native_session_id: "N".repeat(43),
    }
}

fn binding(auth: &CloudSyncNativeAuthMetadata) -> HistoricalBinding<'_> {
    HistoricalBinding {
        snapshot_sha256: SNAPSHOT,
        account_fingerprint: &auth.account_fingerprint,
        protected_store_identity: &auth.protected_store_identity,
    }
}

fn source(auth: &CloudSyncNativeAuthMetadata, sent: bool) -> HistoricalArchiveSource {
    HistoricalArchiveSource::capture(
        &HistoricalRow {
            guid: "historical-client-fixture",
            text: "Historical staging fixture only",
            sender: if sent {
                "owner@example.com"
            } else {
                "peer@example.com"
            },
            peer: "peer@example.com",
            chat_guid: "iMessage;-;peer@example.com",
            date_created_ms: 1_700_000_000_123,
            is_from_me: sent,
        },
        &binding(auth),
        sent,
    )
    .unwrap()
}

fn stage_descriptor(
    value: &CloudSyncNativeHistoricalArchiveSourceBinding,
) -> NativeHistoricalArchiveStage {
    NativeHistoricalArchiveStage {
        message_guid_hash: value.message_guid_hash.clone(),
        source_sha256: value.source_sha256.clone(),
        protected_reference: value.protected_reference.clone(),
        lease_reference: value.lease_reference.clone(),
        payload_sha256: value.payload_sha256.clone(),
        payload_length: value.payload_length,
    }
}

#[tokio::test]
async fn cloudkit_only_historical_capture_keeps_both_origins_and_exact_lease() {
    for sent in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_str().unwrap();
        let auth = metadata(storage);
        let original = source(&auth, sent);
        let bytes = original.encode().unwrap();
        let calls = Cell::new(0);
        let staged = cloud_sync_stage_historical_archive_source_bound(
            storage,
            metadata(storage),
            SNAPSHOT.to_owned(),
            original.source_sha256().unwrap(),
            bytes.clone(),
            || {
                calls.set(calls.get() + 1);
                std::future::ready(Ok(metadata(storage)))
            },
        )
        .await
        .unwrap();
        assert_eq!(calls.get(), 2);
        let descriptor = stage_descriptor(&staged);
        assert!(
            open_historical_archive_source(
                directory.path().to_path_buf(),
                &binding(&auth),
                &descriptor,
            )
            .is_err(),
            "staging alone must not claim journal adoption"
        );
        cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(),
            &staged.lease_reference,
            std::slice::from_ref(&staged.protected_reference),
        )
        .unwrap();
        let reopened = open_historical_archive_source(
            directory.path().to_path_buf(),
            &binding(&auth),
            &descriptor,
        )
        .unwrap();
        assert_eq!(reopened.encode().unwrap(), bytes);
        assert_eq!(staged.source_sha256, original.source_sha256().unwrap());
        assert_eq!(staged.account_fingerprint, auth.account_fingerprint);
        assert_eq!(
            staged.protected_store_identity,
            auth.protected_store_identity
        );
    }
}

#[tokio::test]
async fn cloudkit_only_historical_capture_rejects_stale_identity_before_staging() {
    let directory = tempfile::tempdir().unwrap();
    let storage = directory.path().to_str().unwrap();
    let mut expected = metadata(storage);
    expected.native_session_id = "M".repeat(43);
    let calls = Cell::new(0);
    let result = cloud_sync_stage_historical_archive_source_bound(
        storage,
        expected,
        SNAPSHOT.to_owned(),
        "a".repeat(64),
        vec![0],
        || {
            calls.set(calls.get() + 1);
            std::future::ready(Ok(metadata(storage)))
        },
    )
    .await;
    assert_eq!(
        result.unwrap_err().to_string(),
        "cloud_sync_historical_archive_identity_changed"
    );
    assert_eq!(
        calls.get(),
        1,
        "mismatched identity must fail before source parsing"
    );
    let recovery =
        cloud_sync_recover_abandoned_page_leases(directory.path().to_path_buf(), &[], &[], true)
            .unwrap();
    assert_eq!(recovery.rolled_back, 0);
}

#[tokio::test]
async fn cloudkit_only_historical_capture_rolls_back_only_fresh_unadopted_stage() {
    for changed_field in 0..4 {
        let directory = tempfile::tempdir().unwrap();
        let storage = directory.path().to_str().unwrap();
        let auth = metadata(storage);
        let original = source(&auth, false);
        let original_bytes = original.encode().unwrap();
        let retained = crate::cloud_sync_historical_source_stage::stage_historical_archive_source(
            directory.path().to_path_buf(),
            &binding(&auth),
            &original.source_sha256().unwrap(),
            &original_bytes,
        )
        .unwrap();
        cloud_sync_commit_protected_page_lease(
            directory.path().to_path_buf(),
            &retained.lease_reference,
            std::slice::from_ref(&retained.protected_reference),
        )
        .unwrap();
        let calls = Cell::new(0);
        let result = cloud_sync_stage_historical_archive_source_bound(
            storage,
            metadata(storage),
            SNAPSHOT.to_owned(),
            original.source_sha256().unwrap(),
            original_bytes.clone(),
            || {
                calls.set(calls.get() + 1);
                let mut actual = metadata(storage);
                if calls.get() == 2 {
                    match changed_field {
                        0 => actual.account_fingerprint = "B".repeat(43),
                        1 => {
                            actual.protected_store_identity =
                                format!("obcs2.store.{}", "T".repeat(43))
                        }
                        2 => actual.native_session_id = "M".repeat(43),
                        _ => return std::future::ready(Err(anyhow!("private provider failure"))),
                    }
                }
                std::future::ready(Ok(actual))
            },
        )
        .await;
        assert_eq!(calls.get(), 2);
        assert_eq!(
            result.unwrap_err().to_string(),
            if changed_field == 3 {
                "cloud_sync_historical_archive_identity_unavailable"
            } else {
                "cloud_sync_historical_archive_identity_changed"
            }
        );
        let recovery = cloud_sync_recover_abandoned_page_leases(
            directory.path().to_path_buf(),
            std::slice::from_ref(&retained.lease_reference),
            std::slice::from_ref(&retained.protected_reference),
            true,
        )
        .unwrap();
        assert_eq!(
            recovery.rolled_back, 0,
            "fresh failed stage was already rolled back"
        );
        assert_eq!(
            open_historical_archive_source(
                directory.path().to_path_buf(),
                &binding(&auth),
                &retained,
            )
            .unwrap()
            .encode()
            .unwrap(),
            original_bytes,
            "older adopted source survives"
        );
    }
}
