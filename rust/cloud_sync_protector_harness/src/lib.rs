//! Lightweight host harness for the platform-neutral Cloud Sync protector
//! envelope, HMAC, corruption, and race tests.
//!
//! The full application crate pulls in legacy platform dependencies that do
//! not build on every development host. Keeping this harness dependency-small
//! lets those security invariants run independently.

#![allow(dead_code)]

#[cfg(target_os = "windows")]
#[path = "../../src/windows_secret_storage.rs"]
mod windows_secret_storage;

// The protector derives its native-only semantic identifier hasher from the
// same per-install secret, so the harness links that hasher and the canonical
// validation types it reports through. Both are dependency-light by design.
#[path = "../../src/cloud_sync_canonical_dto.rs"]
mod cloud_sync_canonical_dto;

// Share the real metadata validator without pulling archive decoding, IDS,
// APNs or the full rustpush dependency graph into this protector-only harness.
#[path = "../../src/cloud_sync_extension_metadata.rs"]
mod cloud_sync_extension_metadata;

#[path = "../../src/cloud_sync_semantic_identity.rs"]
mod cloud_sync_semantic_identity;

#[path = "../../src/cloud_sync_protector.rs"]
mod cloud_sync_protector;

#[cfg(test)]
mod shared_contract_tests {
    use super::cloud_sync_extension_metadata::*;

    #[test]
    fn real_extension_schema_is_shared_without_archive_or_network_dependencies() {
        let mut metadata = ExtensionPayloadMetadata {
            name: "Synthetic".into(),
            app_id: None,
            bundle_id: "com.example.synthetic".into(),
            balloon: ExtensionBalloonMetadata {
                url: "app:fixture".into(),
                session: None,
                ld_text: None,
                is_live: true,
                icon: Some(vec![1, 2, 3]),
                layout: None,
            },
        };
        let context = ExtensionSessionContext {
            role: ExtensionSessionRole::Update,
            session_guid: "source-guid".into(),
            session_logical_key_hash: "A".repeat(43),
        };
        let bytes = serialize_session_metadata_json(&metadata, &context).unwrap();
        let (decoded, decoded_context) = parse_projection_metadata_json(&bytes).unwrap();
        assert_eq!(decoded, metadata);
        assert!(decoded_context.as_ref() == Some(&context));
        let mut invalid: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        invalid["context"]["unexpected"] = serde_json::json!(true);
        assert!(parse_projection_metadata_json(&serde_json::to_vec(&invalid).unwrap()).is_err());
        metadata.balloon.icon = Some(vec![0; MAX_ICON_BYTES + 1]);
        assert_eq!(
            serialize_generated_metadata_json(&metadata),
            Err(ExtensionPayloadFailure::LimitExceeded)
        );
    }
}
