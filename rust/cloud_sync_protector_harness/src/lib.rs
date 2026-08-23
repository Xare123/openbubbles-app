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

#[path = "../../src/cloud_sync_semantic_identity.rs"]
mod cloud_sync_semantic_identity;

#[path = "../../src/cloud_sync_protector.rs"]
mod cloud_sync_protector;
