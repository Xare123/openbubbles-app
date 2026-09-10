//! Bounded native durable byte-upload receipt store for attachment uploads.
//!
//! One-shot semantics for the native upload consumer: claim_attempt takes
//! exclusive durable ownership of a single upload attempt BEFORE any byte
//! I/O; persist_completed durably records the already-validated encoded
//! native attachment envelope; recover_completed returns those bytes only
//! under the exact original binding.
//!
//! A claim is ownership, not proof. Claim presence MUST NOT be read as byte
//! upload succeeded. Only a recovered completed receipt proves the envelope
//! was staged, and the parent still revalidates it against the original plan
//! and stages it for Dart only while the local journal is still
//! started/unknown (never when already adopted).
//!
//! Design notes:
//! - Claim and completion are separate create-only files; a different result
//!   never overwrites, and an identical retry is idempotent.
//! - Filenames are keyed hashes of the full binding; no raw attempt ids,
//!   account fingerprints, or plan hashes appear in filenames.
//! - File contents are platform-protected ciphertext only (scope:
//!   account/private/attachmentManateeZone/messages/schema2, purpose
//!   attachmentUploadReceipt); plan SHA, store identity, and attempt id are
//!   bound inside the protected envelope.
//! - There is intentionally no deletion API. Partial or corrupt state stays
//!   fail-closed.
//!
//! Parent wiring (outside this file): lib.rs module declaration plus the
//! one-shot FRB upload consumer, and the attachmentUploadReceipt purpose in
//! the cloud_sync_protector allowlist with a separation test.
//! Directory sync follows the cloud_sync_native_fetch pattern: real fsync
//! on unix, no-op on Windows (never File::open on a Windows directory).

#![cfg_attr(not(test), allow(dead_code))]

use std::{
    fmt::{self, Debug},
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Mutex, MutexGuard},
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use thiserror::Error;
use uuid::Uuid;

use crate::cloud_sync_protector::{self, CloudSyncProtectionError};

/// Maximum accepted completed envelope: already-validated encoded native
/// attachment envelope bytes.
pub(crate) const MAX_COMPLETED_ENVELOPE_BYTES: usize = 2 * 1024 * 1024;

const MAX_CLAIM_FILE_BYTES: u64 = 64 * 1024;
const MAX_COMPLETED_FILE_BYTES: u64 = 8 * 1024 * 1024;
const STORE_DIRECTORY_NAME: &str = "cloud_sync_v2_native_store";
const RECEIPT_DIRECTORY_NAME: &str = ".attachment-upload-receipts";
const RECEIPT_FILE_PREFIX: &str = "obcs2.upload.";
const CLAIM_SUFFIX: &str = ".claim";
const COMPLETED_SUFFIX: &str = ".completed";
const RECEIPT_ID_DOMAIN: &[u8] =
    b"OpenBubbles Cloud Sync V2 attachment upload receipt identity v1\0";
const CLAIM_MAGIC: &str = "OBCS2-ATTACHMENT-UPLOAD-CLAIM";
const COMPLETED_MAGIC: &str = "OBCS2-ATTACHMENT-UPLOAD-RECEIPT";
const RECEIPT_FORMAT_VERSION: &str = "v1";
const PROTECTOR_CONTAINER: &str = "com.apple.messages.cloud";
const PROTECTOR_DATABASE: &str = "private";
const PROTECTOR_ZONE: &str = "attachmentManateeZone";
const PROTECTOR_STREAM_KIND: &str = "messages";
const PROTECTOR_SCHEMA_VERSION: u32 = 2;
const PROTECTOR_PURPOSE: &str = "attachmentUploadReceipt";

static RECEIPT_OPERATION_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub(crate) enum ReceiptFailure {
    #[error("attachment upload receipt storage is invalid")]
    InvalidStorage,
    #[error("attachment upload receipt binding is invalid")]
    InvalidBinding,
    #[error("attachment upload attempt was already claimed")]
    AlreadyClaimed,
    #[error("attachment upload attempt has no prior claim")]
    MissingClaim,
    #[error("attachment upload receipt already records a different result")]
    ResultMismatch,
    #[error("attachment upload receipt is corrupt")]
    CorruptReceipt,
    #[error("attachment upload receipt belongs to a different context")]
    ContextMismatch,
    #[error("attachment upload receipt protection is unavailable")]
    ProtectionUnavailable,
    #[error("attachment upload receipt I/O failed")]
    Io,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct AttachmentUploadReceiptBinding {
    pub account_fingerprint: String,
    pub protected_store_identity: String,
    pub plan_payload_sha256: String,
    pub upload_attempt_id: String,
}

impl Debug for AttachmentUploadReceiptBinding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AttachmentUploadReceiptBinding(..)")
    }
}

fn is_bare_digest(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn is_hex_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn is_protected_store_identity(value: &str) -> bool {
    value
        .strip_prefix("obcs2.store.")
        .is_some_and(is_bare_digest)
}

fn is_attempt_id(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|id| {
        id.get_version() == Some(uuid::Version::Random) && id.to_string().to_uppercase() == value
    })
}

fn validate_binding(binding: &AttachmentUploadReceiptBinding) -> Result<(), ReceiptFailure> {
    if !is_bare_digest(&binding.account_fingerprint)
        || !is_protected_store_identity(&binding.protected_store_identity)
        || !is_hex_digest(&binding.plan_payload_sha256)
        || !is_attempt_id(&binding.upload_attempt_id)
    {
        return Err(ReceiptFailure::InvalidBinding);
    }
    Ok(())
}

fn operation_guard() -> Result<MutexGuard<'static, ()>, ReceiptFailure> {
    RECEIPT_OPERATION_LOCK
        .lock()
        .map_err(|_| ReceiptFailure::Io)
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), ReceiptFailure> {
    std::fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| ReceiptFailure::Io)
}

/// Windows exposes no directory-sync primitive; established native-fetch
/// practice is a no-op here rather than opening a directory handle.
#[cfg(windows)]
fn sync_directory(_path: &Path) -> Result<(), ReceiptFailure> {
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn sync_directory(_path: &Path) -> Result<(), ReceiptFailure> {
    Err(ReceiptFailure::ProtectionUnavailable)
}

fn map_protection_error(error: CloudSyncProtectionError) -> ReceiptFailure {
    match error {
        CloudSyncProtectionError::ContextMismatch | CloudSyncProtectionError::PlatformMismatch => {
            ReceiptFailure::ContextMismatch
        }
        CloudSyncProtectionError::InvalidProtectedValue
        | CloudSyncProtectionError::UnsupportedFormat => ReceiptFailure::CorruptReceipt,
        CloudSyncProtectionError::InvalidStorageDirectory => ReceiptFailure::InvalidStorage,
        CloudSyncProtectionError::InvalidContext
        | CloudSyncProtectionError::KeyUnavailable
        | CloudSyncProtectionError::UnsupportedPlatform
        | CloudSyncProtectionError::InvalidSecretStorage
        | CloudSyncProtectionError::MissingSecretStorage
        | CloudSyncProtectionError::SecretStorage => ReceiptFailure::ProtectionUnavailable,
    }
}

fn validate_storage_root(storage_directory: &Path) -> Result<PathBuf, ReceiptFailure> {
    let metadata =
        fs::symlink_metadata(storage_directory).map_err(|_| ReceiptFailure::InvalidStorage)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(ReceiptFailure::InvalidStorage);
    }
    Ok(storage_directory.to_path_buf())
}

fn check_receipt_dir_containment(
    storage_root: &Path,
    store_dir: &Path,
    receipt_dir: &Path,
) -> Result<(), ReceiptFailure> {
    for path in [store_dir, receipt_dir] {
        let metadata = fs::symlink_metadata(path).map_err(|_| ReceiptFailure::Io)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(ReceiptFailure::InvalidStorage);
        }
    }
    let canonical_root = fs::canonicalize(storage_root).map_err(|_| ReceiptFailure::Io)?;
    let canonical_store = fs::canonicalize(store_dir).map_err(|_| ReceiptFailure::Io)?;
    let canonical_receipt = fs::canonicalize(receipt_dir).map_err(|_| ReceiptFailure::Io)?;
    if canonical_store != canonical_root.join(STORE_DIRECTORY_NAME)
        || canonical_receipt != canonical_store.join(RECEIPT_DIRECTORY_NAME)
    {
        return Err(ReceiptFailure::InvalidStorage);
    }
    Ok(())
}

fn ensure_directories(storage_root: &Path) -> Result<(PathBuf, PathBuf), ReceiptFailure> {
    let store_dir = storage_root.join(STORE_DIRECTORY_NAME);
    let receipt_dir = store_dir.join(RECEIPT_DIRECTORY_NAME);
    // Create and validate each child before traversing it. create_dir_all
    // would follow an existing store symlink and write outside this profile.
    for directory in [&store_dir, &receipt_dir] {
        match fs::create_dir(directory) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => return Err(ReceiptFailure::Io),
        }
        let metadata = fs::symlink_metadata(directory).map_err(|_| ReceiptFailure::Io)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(ReceiptFailure::InvalidStorage);
        }
    }
    // First-durable-artifact barrier: repair the parent chain before the
    // receipt is reported durable.
    sync_directory(storage_root)?;
    sync_directory(&store_dir)?;
    sync_directory(&receipt_dir)?;
    check_receipt_dir_containment(storage_root, &store_dir, &receipt_dir)?;
    Ok((store_dir, receipt_dir))
}

fn check_store_identity(
    storage_root: &Path,
    binding: &AttachmentUploadReceiptBinding,
) -> Result<(), ReceiptFailure> {
    let actual =
        cloud_sync_protector::protected_store_identity(storage_root.to_string_lossy().into_owned())
            .map_err(map_protection_error)?;
    if actual != binding.protected_store_identity {
        return Err(ReceiptFailure::ContextMismatch);
    }
    Ok(())
}

fn protect_text(
    storage_root: &Path,
    binding: &AttachmentUploadReceiptBinding,
    plaintext: String,
) -> Result<String, ReceiptFailure> {
    cloud_sync_protector::protect(
        storage_root.to_string_lossy().into_owned(),
        binding.account_fingerprint.clone(),
        PROTECTOR_CONTAINER.to_owned(),
        PROTECTOR_DATABASE.to_owned(),
        PROTECTOR_ZONE.to_owned(),
        PROTECTOR_STREAM_KIND.to_owned(),
        PROTECTOR_SCHEMA_VERSION,
        PROTECTOR_PURPOSE.to_owned(),
        plaintext,
    )
    .map_err(map_protection_error)
}

fn unprotect_text(
    storage_root: &Path,
    binding: &AttachmentUploadReceiptBinding,
    ciphertext: String,
) -> Result<String, ReceiptFailure> {
    cloud_sync_protector::unprotect(
        storage_root.to_string_lossy().into_owned(),
        binding.account_fingerprint.clone(),
        PROTECTOR_CONTAINER.to_owned(),
        PROTECTOR_DATABASE.to_owned(),
        PROTECTOR_ZONE.to_owned(),
        PROTECTOR_STREAM_KIND.to_owned(),
        PROTECTOR_SCHEMA_VERSION,
        PROTECTOR_PURPOSE.to_owned(),
        ciphertext,
    )
    .map_err(map_protection_error)
}

fn receipt_token(
    storage_root: &Path,
    binding: &AttachmentUploadReceiptBinding,
) -> Result<String, ReceiptFailure> {
    let identity = [
        binding.account_fingerprint.as_str(),
        binding.protected_store_identity.as_str(),
        binding.plan_payload_sha256.as_str(),
        binding.upload_attempt_id.as_str(),
    ]
    .join("\u{1f}");
    let token = cloud_sync_protector::semantic_identifier_hasher(
        storage_root.to_string_lossy().into_owned(),
    )
    .map_err(map_protection_error)?
    .digest(RECEIPT_ID_DOMAIN, &identity);
    if !is_bare_digest(&token) {
        return Err(ReceiptFailure::ProtectionUnavailable);
    }
    Ok(token)
}

fn join_receipt_file(
    receipt_dir: &Path,
    token: &str,
    suffix: &str,
) -> Result<PathBuf, ReceiptFailure> {
    if !is_bare_digest(token) {
        return Err(ReceiptFailure::ProtectionUnavailable);
    }
    let path = receipt_dir.join(format!("{RECEIPT_FILE_PREFIX}{token}{suffix}"));
    if !path.starts_with(receipt_dir) || path.file_name().and_then(|name| name.to_str()).is_none() {
        return Err(ReceiptFailure::InvalidStorage);
    }
    Ok(path)
}

fn encode_claim_plaintext(binding: &AttachmentUploadReceiptBinding) -> String {
    [
        CLAIM_MAGIC,
        RECEIPT_FORMAT_VERSION,
        binding.account_fingerprint.as_str(),
        binding.protected_store_identity.as_str(),
        binding.plan_payload_sha256.as_str(),
        binding.upload_attempt_id.as_str(),
    ]
    .join("\n")
}

fn encode_completed_plaintext(
    binding: &AttachmentUploadReceiptBinding,
    completed_envelope: &[u8],
) -> String {
    let encoded_envelope = URL_SAFE_NO_PAD.encode(completed_envelope);
    [
        COMPLETED_MAGIC,
        RECEIPT_FORMAT_VERSION,
        binding.account_fingerprint.as_str(),
        binding.protected_store_identity.as_str(),
        binding.plan_payload_sha256.as_str(),
        binding.upload_attempt_id.as_str(),
        encoded_envelope.as_str(),
    ]
    .join("\n")
}

fn decode_claim_plaintext(
    plaintext: &str,
    binding: &AttachmentUploadReceiptBinding,
) -> Result<(), ReceiptFailure> {
    let parts: Vec<&str> = plaintext.split('\n').collect();
    if parts.len() != 6
        || parts[0] != CLAIM_MAGIC
        || parts[1] != RECEIPT_FORMAT_VERSION
        || parts[2] != binding.account_fingerprint
        || parts[3] != binding.protected_store_identity
        || parts[4] != binding.plan_payload_sha256
        || parts[5] != binding.upload_attempt_id
    {
        return Err(ReceiptFailure::CorruptReceipt);
    }
    Ok(())
}

fn decode_completed_plaintext(
    plaintext: &str,
    binding: &AttachmentUploadReceiptBinding,
) -> Result<Vec<u8>, ReceiptFailure> {
    let parts: Vec<&str> = plaintext.split('\n').collect();
    if parts.len() != 7 || parts[0] != COMPLETED_MAGIC || parts[1] != RECEIPT_FORMAT_VERSION {
        return Err(ReceiptFailure::CorruptReceipt);
    }
    if parts[2] != binding.account_fingerprint
        || parts[3] != binding.protected_store_identity
        || parts[4] != binding.plan_payload_sha256
        || parts[5] != binding.upload_attempt_id
    {
        return Err(ReceiptFailure::ContextMismatch);
    }
    let envelope = URL_SAFE_NO_PAD
        .decode(parts[6])
        .map_err(|_| ReceiptFailure::CorruptReceipt)?;
    if envelope.is_empty() || envelope.len() > MAX_COMPLETED_ENVELOPE_BYTES {
        return Err(ReceiptFailure::CorruptReceipt);
    }
    Ok(envelope)
}

fn read_file_bytes(path: &Path, max_bytes: u64) -> Result<Vec<u8>, ReceiptFailure> {
    let metadata = fs::symlink_metadata(path).map_err(|_| ReceiptFailure::Io)?;
    if metadata.file_type().is_symlink() {
        return Err(ReceiptFailure::InvalidStorage);
    }
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > max_bytes {
        return Err(ReceiptFailure::CorruptReceipt);
    }
    let mut bytes = Vec::new();
    fs::File::open(path)
        .map_err(|_| ReceiptFailure::Io)?
        .take(max_bytes + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ReceiptFailure::Io)?;
    if bytes.is_empty() || bytes.len() as u64 > max_bytes {
        return Err(ReceiptFailure::CorruptReceipt);
    }
    Ok(bytes)
}

fn read_and_verify_claim(
    storage_root: &Path,
    path: &Path,
    binding: &AttachmentUploadReceiptBinding,
) -> Result<(), ReceiptFailure> {
    let bytes = read_file_bytes(path, MAX_CLAIM_FILE_BYTES)?;
    let protected = String::from_utf8(bytes).map_err(|_| ReceiptFailure::CorruptReceipt)?;
    let plaintext = unprotect_text(storage_root, binding, protected).map_err(|error| {
        if error == ReceiptFailure::ContextMismatch {
            ReceiptFailure::CorruptReceipt
        } else {
            error
        }
    })?;
    decode_claim_plaintext(&plaintext, binding)
}

fn read_and_verify_completed(
    storage_root: &Path,
    path: &Path,
    binding: &AttachmentUploadReceiptBinding,
) -> Result<Vec<u8>, ReceiptFailure> {
    let bytes = read_file_bytes(path, MAX_COMPLETED_FILE_BYTES)?;
    let protected = String::from_utf8(bytes).map_err(|_| ReceiptFailure::CorruptReceipt)?;
    let plaintext = unprotect_text(storage_root, binding, protected)?;
    decode_completed_plaintext(&plaintext, binding)
}

fn atomic_publish(
    receipt_dir: &Path,
    destination: &Path,
    bytes: &[u8],
) -> Result<bool, ReceiptFailure> {
    if !destination.starts_with(receipt_dir) {
        return Err(ReceiptFailure::InvalidStorage);
    }
    let mut file = tempfile::NamedTempFile::new_in(receipt_dir).map_err(|_| ReceiptFailure::Io)?;
    file.write_all(bytes).map_err(|_| ReceiptFailure::Io)?;
    file.as_file().sync_all().map_err(|_| ReceiptFailure::Io)?;
    // rename() replaces an existing destination on Unix. No-clobber publish
    // makes this invariant hold across processes, not only this Rust mutex.
    match file.persist_noclobber(destination) {
        Ok(_) => {
            sync_directory(receipt_dir)?;
            Ok(true)
        }
        Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
        Err(_) => Err(ReceiptFailure::Io),
    }
}

/// Exclusively and durably claims one upload attempt before any byte I/O.
/// The first claim wins; reopening an existing claim NEVER grants another
/// consume, even for the identical binding. A partial or corrupt claim stays
/// fail-closed. Claim presence alone never means the byte upload succeeded.
pub(crate) fn claim_attempt(
    storage_directory: &Path,
    binding: &AttachmentUploadReceiptBinding,
) -> Result<(), ReceiptFailure> {
    let _guard = operation_guard()?;
    validate_binding(binding)?;
    let storage_root = validate_storage_root(storage_directory)?;
    let (_store_dir, receipt_dir) = ensure_directories(&storage_root)?;
    check_store_identity(&storage_root, binding)?;
    let token = receipt_token(&storage_root, binding)?;
    let claim_path = join_receipt_file(&receipt_dir, &token, CLAIM_SUFFIX)?;
    match fs::symlink_metadata(&claim_path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(ReceiptFailure::Io),
        Ok(_) => {
            return match read_and_verify_claim(&storage_root, &claim_path, binding) {
                Ok(()) => Err(ReceiptFailure::AlreadyClaimed),
                Err(error) => Err(error),
            };
        }
    }
    let protected = protect_text(&storage_root, binding, encode_claim_plaintext(binding))?;
    // Atomic O_EXCL/CREATE_NEW is the claim. A partially written claim is
    // deliberately retained and cannot turn into permission to upload again.
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&claim_path)
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                ReceiptFailure::AlreadyClaimed
            } else {
                ReceiptFailure::Io
            }
        })?;
    file.write_all(protected.as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|_| ReceiptFailure::Io)?;
    drop(file);
    sync_directory(&receipt_dir)?;
    read_and_verify_claim(&storage_root, &claim_path, binding)?;
    Ok(())
}

/// Durably persists the already-validated encoded native attachment envelope
/// for a previously claimed attempt. Requires the prior claim, never
/// overwrites a different recorded result, and treats an identical retry as
/// idempotent success.
pub(crate) fn persist_completed(
    storage_directory: &Path,
    binding: &AttachmentUploadReceiptBinding,
    completed_envelope: &[u8],
) -> Result<(), ReceiptFailure> {
    let _guard = operation_guard()?;
    validate_binding(binding)?;
    if completed_envelope.is_empty() || completed_envelope.len() > MAX_COMPLETED_ENVELOPE_BYTES {
        return Err(ReceiptFailure::InvalidBinding);
    }
    let storage_root = validate_storage_root(storage_directory)?;
    let (_store_dir, receipt_dir) = ensure_directories(&storage_root)?;
    check_store_identity(&storage_root, binding)?;
    let token = receipt_token(&storage_root, binding)?;
    let claim_path = join_receipt_file(&receipt_dir, &token, CLAIM_SUFFIX)?;
    let completed_path = join_receipt_file(&receipt_dir, &token, COMPLETED_SUFFIX)?;
    match fs::symlink_metadata(&claim_path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(ReceiptFailure::MissingClaim)
        }
        Err(_) => return Err(ReceiptFailure::Io),
        Ok(_) => read_and_verify_claim(&storage_root, &claim_path, binding)?,
    }
    let protected = protect_text(
        &storage_root,
        binding,
        encode_completed_plaintext(binding, completed_envelope),
    )?;
    match fs::symlink_metadata(&completed_path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let _created = atomic_publish(&receipt_dir, &completed_path, protected.as_bytes())?;
            // A concurrent process may have won publication. Accept it only
            // if it retained exactly the same result, never overwrite it.
            let existing = read_and_verify_completed(&storage_root, &completed_path, binding)?;
            if existing.as_slice() != completed_envelope {
                return Err(ReceiptFailure::ResultMismatch);
            }
            sync_directory(&receipt_dir)?;
            Ok(())
        }
        Err(_) => Err(ReceiptFailure::Io),
        Ok(_) => {
            match read_and_verify_completed(&storage_root, &completed_path, binding) {
                Ok(existing) if existing.as_slice() == completed_envelope => {
                    // Identical retry: repair the directory barrier, then
                    // report idempotent success.
                    sync_directory(&receipt_dir)?;
                    Ok(())
                }
                Ok(_) => Err(ReceiptFailure::ResultMismatch),
                Err(ReceiptFailure::ContextMismatch) => Err(ReceiptFailure::CorruptReceipt),
                Err(error) => Err(error),
            }
        }
    }
}

/// Recovers the completed envelope only under the exact original binding.
/// Missing completion returns None; malformed state errors fail-closed.
pub(crate) fn recover_completed(
    storage_directory: &Path,
    binding: &AttachmentUploadReceiptBinding,
) -> Result<Option<Vec<u8>>, ReceiptFailure> {
    let _guard = operation_guard()?;
    validate_binding(binding)?;
    let storage_root = validate_storage_root(storage_directory)?;
    check_store_identity(&storage_root, binding)?;
    let store_dir = storage_root.join(STORE_DIRECTORY_NAME);
    let receipt_dir = store_dir.join(RECEIPT_DIRECTORY_NAME);
    match fs::symlink_metadata(&receipt_dir) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(ReceiptFailure::Io),
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                return Err(ReceiptFailure::InvalidStorage);
            }
            if !metadata.is_dir() {
                return Err(ReceiptFailure::CorruptReceipt);
            }
        }
    }
    check_receipt_dir_containment(&storage_root, &store_dir, &receipt_dir)?;
    let token = receipt_token(&storage_root, binding)?;
    let claim_path = join_receipt_file(&receipt_dir, &token, CLAIM_SUFFIX)?;
    let completed_path = join_receipt_file(&receipt_dir, &token, COMPLETED_SUFFIX)?;
    let has_claim = match fs::symlink_metadata(&claim_path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(_) => return Err(ReceiptFailure::Io),
        Ok(_) => {
            read_and_verify_claim(&storage_root, &claim_path, binding)?;
            true
        }
    };
    let completed = match fs::symlink_metadata(&completed_path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(ReceiptFailure::Io),
        Ok(_) => read_and_verify_completed(&storage_root, &completed_path, binding)?,
    };
    // A completed receipt without its claim is malformed state: stay
    // fail-closed instead of handing bytes to a caller that never owned the
    // attempt.
    if !has_claim {
        return Err(ReceiptFailure::CorruptReceipt);
    }
    Ok(Some(completed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use tempfile::tempdir;

    fn plan_hex(label: &str) -> String {
        format!("{:x}", Sha256::digest(label.as_bytes()))
    }

    fn attempt_id(label: &str) -> String {
        let hex = plan_hex(label).to_uppercase();
        format!(
            "{}-{}-4{}-8{}-{}",
            &hex[..8],
            &hex[8..12],
            &hex[13..16],
            &hex[17..20],
            &hex[20..32]
        )
    }

    fn test_binding(
        storage: &Path,
        attempt_label: &str,
        plan_label: &str,
    ) -> AttachmentUploadReceiptBinding {
        let root = storage.to_string_lossy().into_owned();
        let account = cloud_sync_protector::fingerprint_account(
            root.clone(),
            "synthetic-test-account".to_owned(),
        )
        .expect("test account fingerprint");
        let store =
            cloud_sync_protector::protected_store_identity(root).expect("test store identity");
        AttachmentUploadReceiptBinding {
            account_fingerprint: account,
            protected_store_identity: store,
            plan_payload_sha256: plan_hex(plan_label),
            upload_attempt_id: attempt_id(attempt_label),
        }
    }

    fn receipt_dir_for(storage: &Path) -> PathBuf {
        storage
            .join(STORE_DIRECTORY_NAME)
            .join(RECEIPT_DIRECTORY_NAME)
    }

    #[test]
    fn concurrent_publication_without_process_mutex_never_overwrites() {
        let dir = tempdir().unwrap();
        let target = dir.path().join("test.completed");
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let mut joins = Vec::new();
        for byte in [1u8, 2u8] {
            let root = dir.path().to_owned();
            let target = target.clone();
            let barrier = barrier.clone();
            joins.push(std::thread::spawn(move || {
                barrier.wait();
                (byte, atomic_publish(&root, &target, &[byte; 32]).unwrap())
            }));
        }
        let outcomes: Vec<_> = joins.into_iter().map(|join| join.join().unwrap()).collect();
        assert_eq!(outcomes.iter().filter(|(_, created)| *created).count(), 1);
        let winning_byte = outcomes.iter().find(|(_, created)| *created).unwrap().0;
        assert_eq!(fs::read(target).unwrap(), [winning_byte; 32]);
    }

    #[test]
    fn partial_claim_is_retained_and_cannot_grant_upload_or_recovery() {
        let dir = tempdir().unwrap();
        let binding = test_binding(dir.path(), "partial", "partial");
        let (_, receipt_dir) = ensure_directories(dir.path()).unwrap();
        let token = receipt_token(dir.path(), &binding).unwrap();
        let claim_path = join_receipt_file(&receipt_dir, &token, CLAIM_SUFFIX).unwrap();
        fs::write(&claim_path, b"").unwrap();
        assert!(claim_attempt(dir.path(), &binding).is_err());
        assert!(recover_completed(dir.path(), &binding).is_err());
        assert_eq!(fs::metadata(claim_path).unwrap().len(), 0);
    }

    #[cfg(unix)]
    #[test]
    fn symlink_store_is_rejected_before_creating_any_external_files() {
        let dir = tempdir().unwrap();
        let outside = tempdir().unwrap();
        let binding = test_binding(dir.path(), "symlink", "symlink");
        std::os::unix::fs::symlink(outside.path(), dir.path().join(STORE_DIRECTORY_NAME)).unwrap();
        assert!(claim_attempt(dir.path(), &binding).is_err());
        assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 0);
    }

    #[test]
    fn round_trip_stores_only_ciphertext_under_keyed_names() {
        let dir = tempdir().expect("tempdir");
        let binding = test_binding(dir.path(), "attempt-1", "plan-1");
        let envelope = b"synthetic-secret-envelope-payload-1".repeat(64);
        claim_attempt(dir.path(), &binding).expect("claim");
        persist_completed(dir.path(), &binding, &envelope).expect("persist");
        let recovered = recover_completed(dir.path(), &binding)
            .expect("recover")
            .expect("completed present");
        assert_eq!(recovered, envelope);
        let names: Vec<String> = fs::read_dir(receipt_dir_for(dir.path()))
            .expect("list")
            .map(|entry| {
                entry
                    .expect("entry")
                    .file_name()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        assert_eq!(names.len(), 2);
        for name in &names {
            assert!(!name.contains(&binding.upload_attempt_id));
            assert!(!name.contains(&binding.account_fingerprint));
            assert!(!name.contains(&binding.plan_payload_sha256));
        }
        for name in &names {
            let blob = fs::read(receipt_dir_for(dir.path()).join(name)).expect("read file");
            assert!(!blob
                .windows(envelope.len())
                .any(|w| w == envelope.as_slice()));
        }
    }

    #[test]
    fn duplicate_claim_never_grants_consume() {
        let dir = tempdir().expect("tempdir");
        let binding = test_binding(dir.path(), "attempt-2", "plan-2");
        claim_attempt(dir.path(), &binding).expect("first claim");
        assert_eq!(
            claim_attempt(dir.path(), &binding),
            Err(ReceiptFailure::AlreadyClaimed)
        );
        // A claim alone is not upload success.
        assert_eq!(recover_completed(dir.path(), &binding), Ok(None));
        persist_completed(dir.path(), &binding, b"envelope-bytes").expect("persist");
        assert_eq!(
            claim_attempt(dir.path(), &binding),
            Err(ReceiptFailure::AlreadyClaimed)
        );
    }

    #[test]
    fn identical_replay_is_idempotent_and_different_result_never_overwrites() {
        let dir = tempdir().expect("tempdir");
        let binding = test_binding(dir.path(), "attempt-3", "plan-3");
        claim_attempt(dir.path(), &binding).expect("claim");
        let first = b"first-envelope".repeat(8);
        persist_completed(dir.path(), &binding, &first).expect("persist");
        persist_completed(dir.path(), &binding, &first).expect("identical replay");
        assert_eq!(
            persist_completed(dir.path(), &binding, b"other-envelope"),
            Err(ReceiptFailure::ResultMismatch)
        );
        let recovered = recover_completed(dir.path(), &binding)
            .expect("recover")
            .expect("present");
        assert_eq!(recovered, first);
    }

    #[test]
    fn changed_binding_is_isolated_and_result_without_claim_fails() {
        let dir = tempdir().expect("tempdir");
        let binding = test_binding(dir.path(), "attempt-4", "plan-4");
        claim_attempt(dir.path(), &binding).expect("claim");
        persist_completed(dir.path(), &binding, b"envelope-4").expect("persist");
        let other_attempt = AttachmentUploadReceiptBinding {
            upload_attempt_id: attempt_id("attempt-4b"),
            ..binding.clone()
        };
        assert_eq!(recover_completed(dir.path(), &other_attempt), Ok(None));
        assert_eq!(
            persist_completed(dir.path(), &other_attempt, b"envelope-4"),
            Err(ReceiptFailure::MissingClaim)
        );
        let other_plan = AttachmentUploadReceiptBinding {
            plan_payload_sha256: plan_hex("plan-4b"),
            ..binding.clone()
        };
        assert_eq!(recover_completed(dir.path(), &other_plan), Ok(None));
        let foreign_store = AttachmentUploadReceiptBinding {
            protected_store_identity: "obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                .to_owned(),
            ..binding.clone()
        };
        assert!(claim_attempt(dir.path(), &foreign_store).is_err());
    }

    #[test]
    fn corrupted_completed_receipt_fails_closed() {
        let dir = tempdir().expect("tempdir");
        let binding = test_binding(dir.path(), "attempt-5", "plan-5");
        claim_attempt(dir.path(), &binding).expect("claim");
        let envelope = b"envelope-5".repeat(8);
        persist_completed(dir.path(), &binding, &envelope).expect("persist");
        let token = receipt_token(dir.path(), &binding).expect("token");
        let path = receipt_dir_for(dir.path())
            .join(format!("{RECEIPT_FILE_PREFIX}{token}{COMPLETED_SUFFIX}"));
        let mut bytes = fs::read(&path).expect("read completed");
        bytes.truncate(bytes.len() / 2);
        fs::write(&path, &bytes).expect("corrupt completed");
        assert!(recover_completed(dir.path(), &binding).is_err());
        assert!(persist_completed(dir.path(), &binding, &envelope).is_err());
    }

    #[test]
    fn result_without_claim_and_envelope_size_bounds_fail() {
        let dir = tempdir().expect("tempdir");
        let binding = test_binding(dir.path(), "attempt-6", "plan-6");
        assert_eq!(
            persist_completed(dir.path(), &binding, b"no-claim-envelope"),
            Err(ReceiptFailure::MissingClaim)
        );
        assert_eq!(recover_completed(dir.path(), &binding), Ok(None));
        claim_attempt(dir.path(), &binding).expect("claim");
        assert_eq!(
            persist_completed(dir.path(), &binding, &[]),
            Err(ReceiptFailure::InvalidBinding)
        );
        assert_eq!(
            persist_completed(
                dir.path(),
                &binding,
                &vec![0xA5u8; MAX_COMPLETED_ENVELOPE_BYTES + 1]
            ),
            Err(ReceiptFailure::InvalidBinding)
        );
        let exact = vec![0xA5u8; MAX_COMPLETED_ENVELOPE_BYTES];
        persist_completed(dir.path(), &binding, &exact).expect("exact max persists");
        let recovered = recover_completed(dir.path(), &binding)
            .expect("recover")
            .expect("present");
        assert_eq!(recovered.len(), MAX_COMPLETED_ENVELOPE_BYTES);
    }
}
