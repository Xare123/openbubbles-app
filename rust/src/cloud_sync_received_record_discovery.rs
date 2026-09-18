//! Authenticated read-only record discovery for a protected received source.
//!
//! Discovery answers exactly one question: does the deterministic record for
//! this received GUID exist under the currently authenticated container
//! identity, and if so, which ETag and original raw bytes carry it?
//!
//! It is not owner selection. It never chooses between candidate chats,
//! merges by title or membership, infers uniqueness from a partial page, or
//! accepts a caller-supplied candidate list as authoritative. The record name
//! derives only from the exact GUID plus the container-scoped user identity,
//! so alias text never enters lookup: the name either addresses exactly one
//! record or the derivation itself fails. This says nothing about competing
//! chat ownership, which only the normal reader pipeline may decide.
//!
//! Scaffolding status: this module proves binding and settlement rules with
//! unit tests only. Authenticated lookup against the live container and
//! entry into the protected reader pipeline are separate, not yet wired.
//!
//! A `Found` observation is not equivalence, archival, or projection. It only
//! carries the bound ETag and raw bytes the normal protected semantic reader
//! pipeline would require for entry; that entry step is separate and not yet
//! wired. The reader pipeline's own authenticated parent, ownership, and conflict
//! rules still decide whether anything is projected. Discovery grants no create
//! permission, no write authority, and no IDS receipt. `NotFound` is a separate
//! observation with no payload and no retry side effect.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloud_sync_canonical_dto::CloudCanonicalEntityKind;
use crate::cloud_sync_native_fetch::MAX_RAW_RECORD_BYTES;
use crate::cloud_sync_outbound::{
    deterministic_message_record_name, CloudSyncOutboundFailure as Failure,
};
use crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher;

/// Identity pinned before the lookup and revalidated after it. Every field
/// must match across the await or the observation is discarded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DiscoverySnapshot {
    pub(crate) account_fingerprint: String,
    pub(crate) protected_store_identity: String,
    pub(crate) container_user_id: String,
    pub(crate) message_generation: u64,
}

/// Bound lookup material: the exact record name plus its keyed hashes and the
/// preparation snapshot they were derived from. Settlement must prove the
/// request belongs to the settled scope; a request prepared under another
/// scope never validates, even when the caller supplies two matching new
/// snapshots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DiscoveryRequest {
    pub(crate) record_name: String,
    pub(crate) logical_entity_key_hash: String,
    pub(crate) server_record_id_hash: String,
    pub(crate) prepared_snapshot: DiscoverySnapshot,
}

/// Lookup result classes. `Found` carries the receipt ETag and the original
/// raw bytes; nothing here is compared for equivalence yet.
pub(crate) enum DiscoveryLookupOutcome {
    NotFound,
    Found {
        record_name: String,
        etag: String,
        raw_bytes: Vec<u8>,
    },
    TransportFailure,
}

/// Observation classes. `Absent` carries no payload and grants no create
/// permission. `FoundForReaderIngress` carries bound bytes for the normal
/// reader pipeline only.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum DiscoveryDisposition {
    Absent,
    FoundForReaderIngress,
    Unresolved,
    TransportFailed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DiscoveryObservation {
    pub(crate) disposition: DiscoveryDisposition,
    pub(crate) logical_entity_key_hash: String,
    pub(crate) server_record_id_hash: String,
    pub(crate) etag_hash: Option<String>,
    pub(crate) raw_bytes: Option<Vec<u8>>,
}

fn validate_snapshot(snapshot: &DiscoverySnapshot) -> Result<(), Failure> {
    if snapshot.account_fingerprint.is_empty()
        || snapshot.protected_store_identity.is_empty()
        || snapshot.container_user_id.is_empty()
        || snapshot.message_generation == 0
    {
        return Err(Failure::BindingMismatch);
    }
    Ok(())
}

/// Derives the exact bound record name for `guid` under `snapshot`.
/// Identifier validation (exact bytes, no normalization) happens inside the
/// deterministic derivation; anything unnameable is unsupported, never fuzzy.
pub(crate) fn prepare_discovery(
    guid: &str,
    snapshot: &DiscoverySnapshot,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<DiscoveryRequest, Failure> {
    validate_snapshot(snapshot)?;
    let record_name = deterministic_message_record_name(guid, &snapshot.container_user_id)?;
    let logical_entity_key_hash = hasher
        .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, guid)
        .map_err(|_| Failure::BindingMismatch)?
        .value()
        .to_owned();
    Ok(DiscoveryRequest {
        server_record_id_hash: hasher.server_record_id_hash(&record_name),
        record_name,
        logical_entity_key_hash,
        prepared_snapshot: snapshot.clone(),
    })
}

/// Settles a lookup against the pinned `before` identity and the re-captured
/// `after` identity. Any drift in account, store, container identity, or
/// generation discards the observation. Equivalence is never decided here.
pub(crate) fn settle_discovery(
    before: &DiscoverySnapshot,
    after: &DiscoverySnapshot,
    request: &DiscoveryRequest,
    outcome: DiscoveryLookupOutcome,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<DiscoveryObservation, Failure> {
    validate_snapshot(before)?;
    validate_snapshot(after)?;
    if before != after {
        return Err(Failure::BindingMismatch);
    }
    if request.prepared_snapshot != *before {
        return Err(Failure::BindingMismatch);
    }
    let base = DiscoveryObservation {
        disposition: DiscoveryDisposition::Unresolved,
        logical_entity_key_hash: request.logical_entity_key_hash.clone(),
        server_record_id_hash: request.server_record_id_hash.clone(),
        etag_hash: None,
        raw_bytes: None,
    };
    match outcome {
        DiscoveryLookupOutcome::NotFound => Ok(DiscoveryObservation {
            disposition: DiscoveryDisposition::Absent,
            ..base
        }),
        DiscoveryLookupOutcome::TransportFailure => Ok(DiscoveryObservation {
            disposition: DiscoveryDisposition::TransportFailed,
            ..base
        }),
        DiscoveryLookupOutcome::Found {
            record_name,
            etag,
            raw_bytes,
        } => {
            if record_name != request.record_name {
                return Err(Failure::BindingMismatch);
            }
            if etag.is_empty() || raw_bytes.is_empty() || raw_bytes.len() > MAX_RAW_RECORD_BYTES {
                return Err(Failure::MalformedMessage);
            }
            let etag_hash = hasher
                .canonical_etag_hash(&etag)
                .map_err(|_| Failure::BindingMismatch)?
                .value()
                .to_owned();
            Ok(DiscoveryObservation {
                disposition: DiscoveryDisposition::FoundForReaderIngress,
                etag_hash: Some(etag_hash),
                raw_bytes: Some(raw_bytes),
                ..base
            })
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    fn test_hasher() -> CloudSemanticIdentifierHasher {
        CloudSemanticIdentifierHasher::new(b"discovery-contract-test-key").unwrap()
    }

    fn snapshot() -> DiscoverySnapshot {
        DiscoverySnapshot {
            account_fingerprint: "acct-fingerprint".into(),
            protected_store_identity: "obcs2.store.test".into(),
            container_user_id: "container-scoped-user".into(),
            message_generation: 3,
        }
    }

    fn request(hasher: &CloudSemanticIdentifierHasher) -> DiscoveryRequest {
        prepare_discovery("4D2D9E1A-groups-are-exact", &snapshot(), hasher).unwrap()
    }

    #[test]
    fn found_roundtrip_is_stable_and_duplicate_settle_matches() {
        let hasher = test_hasher();
        let snap = snapshot();
        let req = request(&hasher);
        let outcome = || DiscoveryLookupOutcome::Found {
            record_name: req.record_name.clone(),
            etag: "etag-1".into(),
            raw_bytes: vec![9u8; 64],
        };
        let first = settle_discovery(&snap, &snap, &req, outcome(), &hasher).unwrap();
        assert_eq!(
            first.disposition,
            DiscoveryDisposition::FoundForReaderIngress
        );
        assert!(first.etag_hash.is_some());
        assert_eq!(first.raw_bytes.as_ref().unwrap().len(), 64);
        let second = settle_discovery(&snap, &snap, &req, outcome(), &hasher).unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn not_found_is_absent_with_no_payload_and_no_create_grant() {
        let hasher = test_hasher();
        let snap = snapshot();
        let req = request(&hasher);
        let obs = settle_discovery(
            &snap,
            &snap,
            &req,
            DiscoveryLookupOutcome::NotFound,
            &hasher,
        )
        .unwrap();
        assert_eq!(obs.disposition, DiscoveryDisposition::Absent);
        assert!(obs.etag_hash.is_none());
        assert!(obs.raw_bytes.is_none());
    }

    #[test]
    fn transport_failure_has_no_payload() {
        let hasher = test_hasher();
        let snap = snapshot();
        let req = request(&hasher);
        let obs = settle_discovery(
            &snap,
            &snap,
            &req,
            DiscoveryLookupOutcome::TransportFailure,
            &hasher,
        )
        .unwrap();
        assert_eq!(obs.disposition, DiscoveryDisposition::TransportFailed);
        assert!(obs.etag_hash.is_none());
        assert!(obs.raw_bytes.is_none());
    }

    #[test]
    fn stale_identity_across_await_discards_observation() {
        let hasher = test_hasher();
        let before = snapshot();
        let req = request(&hasher);
        let found = || DiscoveryLookupOutcome::Found {
            record_name: req.record_name.clone(),
            etag: "etag-1".into(),
            raw_bytes: vec![1u8; 8],
        };
        let mut stale_account = before.clone();
        stale_account.account_fingerprint = "rotated-account".into();
        assert!(settle_discovery(&before, &stale_account, &req, found(), &hasher).is_err());
        let mut stale_generation = before.clone();
        stale_generation.message_generation = 4;
        assert!(settle_discovery(&before, &stale_generation, &req, found(), &hasher).is_err());
        let mut stale_container = before.clone();
        stale_container.container_user_id = "other-user".into();
        assert!(settle_discovery(&before, &stale_container, &req, found(), &hasher).is_err());
        let mut zeroed = before.clone();
        zeroed.message_generation = 0;
        assert!(prepare_discovery("guid", &zeroed, &hasher).is_err());
    }

    #[test]
    fn mismatched_record_name_or_malformed_found_fails_closed() {
        let hasher = test_hasher();
        let snap = snapshot();
        let req = request(&hasher);
        let wrong = DiscoveryLookupOutcome::Found {
            record_name: "other-record".into(),
            etag: "etag-1".into(),
            raw_bytes: vec![1u8; 8],
        };
        assert!(settle_discovery(&snap, &snap, &req, wrong, &hasher).is_err());
        let empty_etag = DiscoveryLookupOutcome::Found {
            record_name: req.record_name.clone(),
            etag: String::new(),
            raw_bytes: vec![1u8; 8],
        };
        assert!(settle_discovery(&snap, &snap, &req, empty_etag, &hasher).is_err());
        let empty_raw = DiscoveryLookupOutcome::Found {
            record_name: req.record_name.clone(),
            etag: "etag-1".into(),
            raw_bytes: Vec::new(),
        };
        assert!(settle_discovery(&snap, &snap, &req, empty_raw, &hasher).is_err());
        let oversized = DiscoveryLookupOutcome::Found {
            record_name: req.record_name.clone(),
            etag: "etag-1".into(),
            raw_bytes: vec![0u8; MAX_RAW_RECORD_BYTES + 1],
        };
        assert!(settle_discovery(&snap, &snap, &req, oversized, &hasher).is_err());
    }

    #[test]
    fn old_request_against_new_consistent_scope_fails_closed() {
        let hasher = test_hasher();
        let scope_a = snapshot();
        let old = prepare_discovery("4D2D9E1A-groups-are-exact", &scope_a, &hasher).unwrap();
        let mut scope_b = scope_a.clone();
        scope_b.account_fingerprint = "rotated-account".into();
        let new = prepare_discovery("4D2D9E1A-groups-are-exact", &scope_b, &hasher).unwrap();
        // Same GUID and container user still name the same record; only the
        // preparation scope changed. Settlement must still reject the replay.
        assert_eq!(old.record_name, new.record_name);
        // The caller supplies two matching new snapshots, but the request was
        // prepared under the old scope. Settlement must reject it.
        let replay = DiscoveryLookupOutcome::Found {
            record_name: old.record_name.clone(),
            etag: "etag-1".into(),
            raw_bytes: vec![1u8; 8],
        };
        assert!(settle_discovery(&scope_b, &scope_b, &old, replay, &hasher).is_err());
    }

    #[test]
    fn record_names_are_container_scoped_and_byte_exact() {
        let hasher = test_hasher();
        let snap = snapshot();
        let base = prepare_discovery("exact-guid-1", &snap, &hasher).unwrap();
        let mut other_user = snap.clone();
        other_user.container_user_id = "different-user".into();
        let scoped = prepare_discovery("exact-guid-1", &other_user, &hasher).unwrap();
        assert_ne!(base.record_name, scoped.record_name);
        let cased = prepare_discovery("EXACT-GUID-1", &snap, &hasher).unwrap();
        assert_ne!(base.record_name, cased.record_name);
    }
}
