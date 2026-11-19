/// Untrusted liveness hints only. Native sealed-envelope and lease proof checks
/// remain mandatory; these descriptors never grant write authority.
pub struct CloudSyncMessageSourceRootHint {
    pub raw_reference: String,
    pub account_fingerprint: String,
    pub generation: u64,
}

fn unmap_message_source_roots(roots: Vec<CloudSyncMessageSourceRootHint>)
    -> Vec<crate::cloud_sync_native_fetch::MessageSourceRootHint> {
    roots.into_iter().map(|root| crate::cloud_sync_native_fetch::MessageSourceRootHint {
        raw_reference: root.raw_reference,
        account_fingerprint: root.account_fingerprint,
        generation: root.generation,
    }).collect()
}

#[cfg(test)]
mod message_source_hint_bridge_tests {
    use super::*;

    #[test]
    fn hint_dto_preserves_exact_descriptor_and_u64_generation() {
        let roots = unmap_message_source_roots(vec![CloudSyncMessageSourceRootHint {
            raw_reference: format!("obcs2.ref.{}", "a".repeat(43)),
            account_fingerprint: "b".repeat(43), generation: u64::MAX,
        }]);
        assert_eq!(roots.len(), 1);
        assert_eq!(roots[0].raw_reference, format!("obcs2.ref.{}", "a".repeat(43)));
        assert_eq!(roots[0].account_fingerprint, "b".repeat(43));
        assert_eq!(roots[0].generation, u64::MAX);
    }

    #[test]
    fn incomplete_hint_maintenance_rejects_before_storage_access() {
        let directory = std::env::temp_dir().join(format!("hint-bridge-{}", uuid::Uuid::new_v4()));
        let path = directory.to_string_lossy().into_owned();
        let roots = || vec![CloudSyncMessageSourceRootHint {
            raw_reference: format!("obcs2.ref.{}", "a".repeat(43)),
            account_fingerprint: "b".repeat(43), generation: 1,
        }];
        let recovery = cloud_sync_recover_abandoned_page_leases_with_message_source_roots(
            path.clone(), vec![], vec![], false, roots());
        assert!(recovery.recovery.is_none() && recovery.failure.is_some());
        let collection = cloud_sync_collect_protected_garbage_with_message_source_roots(
            path, vec![], false, roots());
        assert!(collection.collection.is_none() && collection.failure.is_some());
        assert!(!directory.exists());
    }
}
