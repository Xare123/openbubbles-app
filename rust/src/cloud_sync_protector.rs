//! Platform protection boundary for Cloud Sync V2.
//!
//! The public entry points deliberately accept every scope component
//! separately. This avoids delimiter ambiguity and makes the complete scope,
//! value purpose, and plaintext part of one authenticated inner envelope.

use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use thiserror::Error;

#[cfg(target_os = "android")]
use keystore::{EncryptMode, KeyType, KeystoreAccessRules};

use crate::cloud_sync_semantic_identity::CloudSemanticIdentifierHasher;
#[cfg(target_os = "android")]
use crate::keystore::{android_native_keystore, NativeKeystore};
#[cfg(target_os = "windows")]
use crate::windows_secret_storage::{
    load_or_create_cloud_sync_install_secret, protect_current_user, unprotect_current_user,
};

const INNER_MAGIC: &[u8] = b"OBCS2-CONTEXT";
const SECRET_MAGIC: &[u8] = b"OBCS2-SECRET";
const FORMAT_VERSION: u16 = 1;
const WINDOWS_PLATFORM_TAG: &str = "windows";
const ANDROID_PLATFORM_TAG: &str = "android";
const CIPHERTEXT_PREFIX: &str = "obcs2";
const INSTALL_SECRET_FILE_NAME: &str = "cloud_sync_v2_install_secret.bin";
const ANDROID_KEY_ALIAS: &str = "openbubbles:cloud-sync:v2:master";
const FINGERPRINT_DOMAIN: &[u8] = b"OpenBubbles Cloud Sync V2 account fingerprint\0";
const IDENTIFIER_KEY_DOMAIN: &[u8] = b"OpenBubbles Cloud Sync V2 semantic identifier key v1\0";
const PROTECTED_STORE_ID_DOMAIN: &[u8] =
    b"OpenBubbles Cloud Sync V2 protected native store identity v1\0";
const INSTALL_SECRET_LENGTH: usize = 32;
const MAX_CONTEXT_FIELD_BYTES: usize = 16 * 1024;
const MAX_PLAINTEXT_BYTES: usize = 16 * 1024 * 1024;
const MAX_PROTECTED_BYTES: usize = MAX_PLAINTEXT_BYTES + 1024 * 1024;
const MIN_GCM_CIPHERTEXT_BYTES: usize = 12 + 16;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Error)]
pub enum CloudSyncProtectionError {
    #[error("Cloud Sync protection is unavailable on this platform")]
    UnsupportedPlatform,
    #[error("Cloud Sync protection storage is unavailable")]
    InvalidStorageDirectory,
    #[error("Cloud Sync protection context is invalid")]
    InvalidContext,
    #[error("Cloud Sync protected value is invalid")]
    InvalidProtectedValue,
    #[error("Cloud Sync protected value belongs to a different context")]
    ContextMismatch,
    #[error("Cloud Sync protected value belongs to a different platform")]
    PlatformMismatch,
    #[error("Cloud Sync protected value format is unsupported")]
    UnsupportedFormat,
    #[error("Cloud Sync protection key is unavailable")]
    KeyUnavailable,
    #[error("Cloud Sync secret storage is invalid")]
    InvalidSecretStorage,
    #[error("Cloud Sync secret storage does not exist")]
    MissingSecretStorage,
    #[error("Cloud Sync secret storage operation failed")]
    SecretStorage,
}

#[derive(Clone, PartialEq, Eq)]
pub struct CloudSyncProtectionContext {
    account_fingerprint: String,
    container: String,
    database: String,
    zone: String,
    stream_kind: String,
    schema_version: u32,
    purpose: String,
}

impl CloudSyncProtectionContext {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        account_fingerprint: String,
        container: String,
        database: String,
        zone: String,
        stream_kind: String,
        schema_version: u32,
        purpose: String,
    ) -> Result<Self, CloudSyncProtectionError> {
        let context = Self {
            account_fingerprint,
            container,
            database,
            zone,
            stream_kind,
            schema_version,
            purpose,
        };
        context.validate()?;
        Ok(context)
    }

    fn validate(&self) -> Result<(), CloudSyncProtectionError> {
        for field in [
            self.account_fingerprint.as_str(),
            self.container.as_str(),
            self.database.as_str(),
            self.zone.as_str(),
        ] {
            validate_nonempty_field(field)?;
        }
        if !matches!(self.stream_kind.as_str(), "messages" | "profiles")
            || self.schema_version == 0
            || !matches!(
                self.purpose.as_str(),
                "checkpointToken"
                    | "serverRecordId"
                    | "systemFields"
                    | "payloadReference"
                    | "rawRecord"
            )
        {
            return Err(CloudSyncProtectionError::InvalidContext);
        }
        Ok(())
    }
}

#[allow(clippy::too_many_arguments)]
pub fn protect(
    storage_directory: String,
    account_fingerprint: String,
    container: String,
    database: String,
    zone: String,
    stream_kind: String,
    schema_version: u32,
    purpose: String,
    plaintext: String,
) -> Result<String, CloudSyncProtectionError> {
    if plaintext.len() > MAX_PLAINTEXT_BYTES {
        return Err(CloudSyncProtectionError::InvalidProtectedValue);
    }
    let context = CloudSyncProtectionContext::new(
        account_fingerprint,
        container,
        database,
        zone,
        stream_kind,
        schema_version,
        purpose,
    )?;
    let storage_directory = validate_storage_directory(&storage_directory)?;
    let authenticated_plaintext = encode_inner(&context, plaintext.as_bytes())?;
    let (platform, protected) = platform_protect(&storage_directory, &authenticated_plaintext)?;
    if protected.is_empty() || protected.len() > MAX_PROTECTED_BYTES {
        return Err(CloudSyncProtectionError::InvalidProtectedValue);
    }
    Ok(format!(
        "{CIPHERTEXT_PREFIX}.{platform}.{}",
        URL_SAFE_NO_PAD.encode(protected)
    ))
}

#[allow(clippy::too_many_arguments)]
pub fn unprotect(
    storage_directory: String,
    account_fingerprint: String,
    container: String,
    database: String,
    zone: String,
    stream_kind: String,
    schema_version: u32,
    purpose: String,
    ciphertext: String,
) -> Result<String, CloudSyncProtectionError> {
    let expected_context = CloudSyncProtectionContext::new(
        account_fingerprint,
        container,
        database,
        zone,
        stream_kind,
        schema_version,
        purpose,
    )?;
    let storage_directory = validate_storage_directory(&storage_directory)?;
    let (platform, protected) = decode_outer(&ciphertext)?;
    let authenticated_plaintext = platform_unprotect(&storage_directory, platform, &protected)?;
    let (actual_context, plaintext) = decode_inner(&authenticated_plaintext)?;
    if actual_context != expected_context {
        return Err(CloudSyncProtectionError::ContextMismatch);
    }
    String::from_utf8(plaintext).map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)
}

pub fn fingerprint_account(
    storage_directory: String,
    raw_account_identifier: String,
) -> Result<String, CloudSyncProtectionError> {
    if raw_account_identifier.is_empty() || raw_account_identifier.len() > MAX_CONTEXT_FIELD_BYTES {
        return Err(CloudSyncProtectionError::InvalidContext);
    }
    let storage_directory = validate_storage_directory(&storage_directory)?;
    let secret = platform_install_secret(&storage_directory)?;
    let mut hmac = HmacSha256::new_from_slice(&secret)
        .map_err(|_| CloudSyncProtectionError::KeyUnavailable)?;
    hmac.update(FINGERPRINT_DOMAIN);
    hmac.update(raw_account_identifier.as_bytes());
    Ok(URL_SAFE_NO_PAD.encode(hmac.finalize().into_bytes()))
}

/// Builds the native-only semantic identifier hasher from a domain-separated
/// per-install key. The key never crosses Flutter Rust Bridge.
pub(crate) fn semantic_identifier_hasher(
    storage_directory: String,
) -> Result<CloudSemanticIdentifierHasher, CloudSyncProtectionError> {
    let storage_directory = validate_storage_directory(&storage_directory)?;
    let secret = platform_install_secret(&storage_directory)?;
    let mut hmac = HmacSha256::new_from_slice(&secret)
        .map_err(|_| CloudSyncProtectionError::KeyUnavailable)?;
    hmac.update(IDENTIFIER_KEY_DOMAIN);
    let identifier_key = hmac.finalize().into_bytes();
    CloudSemanticIdentifierHasher::new(identifier_key)
        .map_err(|_| CloudSyncProtectionError::KeyUnavailable)
}

/// Returns a non-reversible, per-native-store recovery identity.
///
/// The identity is derived only from the protected per-install secret, so it
/// remains stable across Dart wrappers without disclosing a filesystem path.
pub(crate) fn protected_store_identity(
    storage_directory: String,
) -> Result<String, CloudSyncProtectionError> {
    let storage_directory = validate_storage_directory(&storage_directory)?;
    let secret = platform_install_secret(&storage_directory)?;
    let mut hmac = HmacSha256::new_from_slice(&secret)
        .map_err(|_| CloudSyncProtectionError::KeyUnavailable)?;
    hmac.update(PROTECTED_STORE_ID_DOMAIN);
    Ok(format!(
        "obcs2.store.{}",
        URL_SAFE_NO_PAD.encode(hmac.finalize().into_bytes())
    ))
}

fn validate_storage_directory(path: &str) -> Result<PathBuf, CloudSyncProtectionError> {
    if path.is_empty() {
        return Err(CloudSyncProtectionError::InvalidStorageDirectory);
    }
    let path = PathBuf::from(path);
    if !path.is_dir() {
        return Err(CloudSyncProtectionError::InvalidStorageDirectory);
    }
    Ok(path)
}

fn validate_nonempty_field(field: &str) -> Result<(), CloudSyncProtectionError> {
    if field.is_empty() || field.len() > MAX_CONTEXT_FIELD_BYTES {
        return Err(CloudSyncProtectionError::InvalidContext);
    }
    Ok(())
}

fn encode_inner(
    context: &CloudSyncProtectionContext,
    plaintext: &[u8],
) -> Result<Vec<u8>, CloudSyncProtectionError> {
    let mut encoded = Vec::with_capacity(INNER_MAGIC.len() + plaintext.len() + 256);
    encoded.extend_from_slice(INNER_MAGIC);
    encoded.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
    append_bytes(&mut encoded, context.account_fingerprint.as_bytes())?;
    append_bytes(&mut encoded, context.container.as_bytes())?;
    append_bytes(&mut encoded, context.database.as_bytes())?;
    append_bytes(&mut encoded, context.zone.as_bytes())?;
    append_bytes(&mut encoded, context.stream_kind.as_bytes())?;
    encoded.extend_from_slice(&context.schema_version.to_be_bytes());
    append_bytes(&mut encoded, context.purpose.as_bytes())?;
    append_bytes(&mut encoded, plaintext)?;
    Ok(encoded)
}

fn decode_inner(
    encoded: &[u8],
) -> Result<(CloudSyncProtectionContext, Vec<u8>), CloudSyncProtectionError> {
    let mut cursor = ByteCursor::new(encoded);
    cursor.expect(INNER_MAGIC)?;
    if cursor.read_u16()? != FORMAT_VERSION {
        return Err(CloudSyncProtectionError::UnsupportedFormat);
    }
    let account_fingerprint = cursor.read_string(MAX_CONTEXT_FIELD_BYTES)?;
    let container = cursor.read_string(MAX_CONTEXT_FIELD_BYTES)?;
    let database = cursor.read_string(MAX_CONTEXT_FIELD_BYTES)?;
    let zone = cursor.read_string(MAX_CONTEXT_FIELD_BYTES)?;
    let stream_kind = cursor.read_string(MAX_CONTEXT_FIELD_BYTES)?;
    let schema_version = cursor.read_u32()?;
    let purpose = cursor.read_string(MAX_CONTEXT_FIELD_BYTES)?;
    let plaintext = cursor.read_bytes(MAX_PLAINTEXT_BYTES)?.to_vec();
    if !cursor.is_finished() {
        return Err(CloudSyncProtectionError::InvalidProtectedValue);
    }
    let context = CloudSyncProtectionContext::new(
        account_fingerprint,
        container,
        database,
        zone,
        stream_kind,
        schema_version,
        purpose,
    )?;
    Ok((context, plaintext))
}

fn append_bytes(target: &mut Vec<u8>, bytes: &[u8]) -> Result<(), CloudSyncProtectionError> {
    let length =
        u32::try_from(bytes.len()).map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)?;
    target.extend_from_slice(&length.to_be_bytes());
    target.extend_from_slice(bytes);
    Ok(())
}

fn decode_outer(ciphertext: &str) -> Result<(&str, Vec<u8>), CloudSyncProtectionError> {
    if ciphertext.len() > MAX_PROTECTED_BYTES * 2 {
        return Err(CloudSyncProtectionError::InvalidProtectedValue);
    }
    let mut parts = ciphertext.split('.');
    if parts.next() != Some(CIPHERTEXT_PREFIX) {
        return Err(CloudSyncProtectionError::UnsupportedFormat);
    }
    let platform = parts
        .next()
        .ok_or(CloudSyncProtectionError::InvalidProtectedValue)?;
    let encoded = parts
        .next()
        .ok_or(CloudSyncProtectionError::InvalidProtectedValue)?;
    if parts.next().is_some() || encoded.is_empty() {
        return Err(CloudSyncProtectionError::InvalidProtectedValue);
    }
    let protected = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)?;
    if protected.is_empty() || protected.len() > MAX_PROTECTED_BYTES {
        return Err(CloudSyncProtectionError::InvalidProtectedValue);
    }
    Ok((platform, protected))
}

struct ByteCursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> ByteCursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn expect(&mut self, expected: &[u8]) -> Result<(), CloudSyncProtectionError> {
        if self.take(expected.len())? != expected {
            return Err(CloudSyncProtectionError::InvalidProtectedValue);
        }
        Ok(())
    }

    fn read_u16(&mut self) -> Result<u16, CloudSyncProtectionError> {
        let bytes: [u8; 2] = self
            .take(2)?
            .try_into()
            .map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)?;
        Ok(u16::from_be_bytes(bytes))
    }

    fn read_u32(&mut self) -> Result<u32, CloudSyncProtectionError> {
        let bytes: [u8; 4] = self
            .take(4)?
            .try_into()
            .map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)?;
        Ok(u32::from_be_bytes(bytes))
    }

    fn read_bytes(&mut self, max_length: usize) -> Result<&'a [u8], CloudSyncProtectionError> {
        let length = usize::try_from(self.read_u32()?)
            .map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)?;
        if length > max_length {
            return Err(CloudSyncProtectionError::InvalidProtectedValue);
        }
        self.take(length)
    }

    fn read_string(&mut self, max_length: usize) -> Result<String, CloudSyncProtectionError> {
        String::from_utf8(self.read_bytes(max_length)?.to_vec())
            .map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], CloudSyncProtectionError> {
        let end = self
            .offset
            .checked_add(length)
            .ok_or(CloudSyncProtectionError::InvalidProtectedValue)?;
        if end > self.bytes.len() {
            return Err(CloudSyncProtectionError::InvalidProtectedValue);
        }
        let result = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(result)
    }

    fn is_finished(&self) -> bool {
        self.offset == self.bytes.len()
    }
}

#[cfg(target_os = "windows")]
fn platform_protect(
    _storage_directory: &Path,
    plaintext: &[u8],
) -> Result<(&'static str, Vec<u8>), CloudSyncProtectionError> {
    let protected =
        protect_current_user(plaintext).map_err(|_| CloudSyncProtectionError::KeyUnavailable)?;
    Ok((WINDOWS_PLATFORM_TAG, protected))
}

#[cfg(target_os = "windows")]
fn platform_unprotect(
    _storage_directory: &Path,
    platform: &str,
    ciphertext: &[u8],
) -> Result<Vec<u8>, CloudSyncProtectionError> {
    if platform != WINDOWS_PLATFORM_TAG {
        return Err(CloudSyncProtectionError::PlatformMismatch);
    }
    unprotect_current_user(ciphertext).map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)
}

#[cfg(target_os = "windows")]
fn platform_install_secret(
    storage_directory: &Path,
) -> Result<[u8; INSTALL_SECRET_LENGTH], CloudSyncProtectionError> {
    load_or_create_cloud_sync_install_secret(&storage_directory.join(INSTALL_SECRET_FILE_NAME))
        .map_err(|_| CloudSyncProtectionError::InvalidSecretStorage)
}

#[cfg(target_os = "android")]
fn android_keystore() -> Result<&'static dyn NativeKeystore, CloudSyncProtectionError> {
    android_native_keystore()
        .map(|store| store.as_ref())
        .ok_or(CloudSyncProtectionError::KeyUnavailable)
}

#[cfg(target_os = "android")]
fn ensure_android_master_key() -> Result<&'static dyn NativeKeystore, CloudSyncProtectionError> {
    let store = android_keystore()?;
    match store
        .get_key_type(ANDROID_KEY_ALIAS.to_owned())
        .map_err(|_| CloudSyncProtectionError::KeyUnavailable)?
    {
        Some(KeyType::Aes(256)) => return Ok(store),
        Some(_) => return Err(CloudSyncProtectionError::KeyUnavailable),
        None => {}
    }

    let access_rules = KeystoreAccessRules {
        block_modes: vec![EncryptMode::Gcm],
        require_user: false,
        can_encrypt: true,
        can_decrypt: true,
        ..Default::default()
    };
    if store
        .create_key(
            ANDROID_KEY_ALIAS.to_owned(),
            KeyType::Aes(256),
            access_rules,
        )
        .is_err()
    {
        // A concurrent caller may have won the create. Only accept the error
        // when a fresh lookup proves that the exact expected key now exists.
        if !matches!(
            store.get_key_type(ANDROID_KEY_ALIAS.to_owned()),
            Ok(Some(KeyType::Aes(256)))
        ) {
            return Err(CloudSyncProtectionError::KeyUnavailable);
        }
    }
    Ok(store)
}

#[cfg(target_os = "android")]
fn android_encrypt(plaintext: &[u8]) -> Result<Vec<u8>, CloudSyncProtectionError> {
    let store = ensure_android_master_key()?;
    store
        .encrypt(
            ANDROID_KEY_ALIAS.to_owned(),
            plaintext.to_vec(),
            EncryptMode::Gcm,
        )
        .map_err(|_| CloudSyncProtectionError::KeyUnavailable)
}

#[cfg(target_os = "android")]
fn android_decrypt(ciphertext: &[u8]) -> Result<Vec<u8>, CloudSyncProtectionError> {
    if ciphertext.len() < MIN_GCM_CIPHERTEXT_BYTES {
        return Err(CloudSyncProtectionError::InvalidProtectedValue);
    }
    let store = ensure_android_master_key()?;
    store
        .decrypt(
            ANDROID_KEY_ALIAS.to_owned(),
            ciphertext.to_vec(),
            EncryptMode::Gcm,
        )
        .map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)
}

#[cfg(target_os = "android")]
fn platform_protect(
    _storage_directory: &Path,
    plaintext: &[u8],
) -> Result<(&'static str, Vec<u8>), CloudSyncProtectionError> {
    Ok((ANDROID_PLATFORM_TAG, android_encrypt(plaintext)?))
}

#[cfg(target_os = "android")]
fn platform_unprotect(
    _storage_directory: &Path,
    platform: &str,
    ciphertext: &[u8],
) -> Result<Vec<u8>, CloudSyncProtectionError> {
    if platform != ANDROID_PLATFORM_TAG {
        return Err(CloudSyncProtectionError::PlatformMismatch);
    }
    android_decrypt(ciphertext)
}

#[cfg(target_os = "android")]
fn platform_install_secret(
    storage_directory: &Path,
) -> Result<[u8; INSTALL_SECRET_LENGTH], CloudSyncProtectionError> {
    ensure_android_master_key()?;
    load_or_create_encrypted_install_secret(
        &storage_directory.join(INSTALL_SECRET_FILE_NAME),
        android_encrypt,
        android_decrypt,
    )
}

#[cfg(not(any(target_os = "windows", target_os = "android")))]
fn platform_protect(
    _storage_directory: &Path,
    _plaintext: &[u8],
) -> Result<(&'static str, Vec<u8>), CloudSyncProtectionError> {
    Err(CloudSyncProtectionError::UnsupportedPlatform)
}

#[cfg(not(any(target_os = "windows", target_os = "android")))]
fn platform_unprotect(
    _storage_directory: &Path,
    _platform: &str,
    _ciphertext: &[u8],
) -> Result<Vec<u8>, CloudSyncProtectionError> {
    Err(CloudSyncProtectionError::UnsupportedPlatform)
}

#[cfg(not(any(target_os = "windows", target_os = "android")))]
fn platform_install_secret(
    _storage_directory: &Path,
) -> Result<[u8; INSTALL_SECRET_LENGTH], CloudSyncProtectionError> {
    Err(CloudSyncProtectionError::UnsupportedPlatform)
}

fn load_or_create_encrypted_install_secret<Encrypt, Decrypt>(
    path: &Path,
    encrypt: Encrypt,
    decrypt: Decrypt,
) -> Result<[u8; INSTALL_SECRET_LENGTH], CloudSyncProtectionError>
where
    Encrypt: Fn(&[u8]) -> Result<Vec<u8>, CloudSyncProtectionError>,
    Decrypt: Fn(&[u8]) -> Result<Vec<u8>, CloudSyncProtectionError>,
{
    match read_encrypted_install_secret(path, &decrypt) {
        Ok(secret) => return Ok(secret),
        Err(CloudSyncProtectionError::MissingSecretStorage) => {}
        Err(error) => return Err(error),
    }

    let secret: [u8; INSTALL_SECRET_LENGTH] = rand::random();
    let ciphertext = encrypt(&secret)?;
    if ciphertext.len() < MIN_GCM_CIPHERTEXT_BYTES || ciphertext.len() > MAX_PROTECTED_BYTES {
        return Err(CloudSyncProtectionError::InvalidSecretStorage);
    }
    let encoded = encode_secret_file(&ciphertext)?;
    install_secret_file_atomically(path, &encoded)?;

    let installed = read_encrypted_install_secret(path, decrypt)?;
    if installed != secret {
        // Another process may have installed its secret first. That is valid,
        // but the strict read above must be the authoritative result.
        return Ok(installed);
    }
    Ok(secret)
}

fn read_encrypted_install_secret<Decrypt>(
    path: &Path,
    decrypt: Decrypt,
) -> Result<[u8; INSTALL_SECRET_LENGTH], CloudSyncProtectionError>
where
    Decrypt: Fn(&[u8]) -> Result<Vec<u8>, CloudSyncProtectionError>,
{
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Err(CloudSyncProtectionError::MissingSecretStorage)
        }
        Err(_) => return Err(CloudSyncProtectionError::SecretStorage),
    };
    let metadata = file
        .metadata()
        .map_err(|_| CloudSyncProtectionError::SecretStorage)?;
    if metadata.len() == 0 || metadata.len() > MAX_PROTECTED_BYTES as u64 {
        return Err(CloudSyncProtectionError::InvalidSecretStorage);
    }
    let mut encoded = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut encoded)
        .map_err(|_| CloudSyncProtectionError::SecretStorage)?;
    let ciphertext = decode_secret_file(&encoded)?;
    let plaintext = decrypt(ciphertext)?;
    plaintext
        .try_into()
        .map_err(|_| CloudSyncProtectionError::InvalidSecretStorage)
}

fn encode_secret_file(ciphertext: &[u8]) -> Result<Vec<u8>, CloudSyncProtectionError> {
    let mut encoded = Vec::with_capacity(SECRET_MAGIC.len() + ciphertext.len() + 6);
    encoded.extend_from_slice(SECRET_MAGIC);
    encoded.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
    append_bytes(&mut encoded, ciphertext)?;
    Ok(encoded)
}

fn decode_secret_file(encoded: &[u8]) -> Result<&[u8], CloudSyncProtectionError> {
    let mut cursor = ByteCursor::new(encoded);
    cursor
        .expect(SECRET_MAGIC)
        .map_err(|_| CloudSyncProtectionError::InvalidSecretStorage)?;
    if cursor
        .read_u16()
        .map_err(|_| CloudSyncProtectionError::InvalidSecretStorage)?
        != FORMAT_VERSION
    {
        return Err(CloudSyncProtectionError::UnsupportedFormat);
    }
    let ciphertext = cursor
        .read_bytes(MAX_PROTECTED_BYTES)
        .map_err(|_| CloudSyncProtectionError::InvalidSecretStorage)?;
    if ciphertext.len() < MIN_GCM_CIPHERTEXT_BYTES || !cursor.is_finished() {
        return Err(CloudSyncProtectionError::InvalidSecretStorage);
    }
    Ok(ciphertext)
}

fn install_secret_file_atomically(
    path: &Path,
    encoded: &[u8],
) -> Result<(), CloudSyncProtectionError> {
    let parent = path
        .parent()
        .ok_or(CloudSyncProtectionError::InvalidStorageDirectory)?;
    let file_name = path
        .file_name()
        .ok_or(CloudSyncProtectionError::InvalidStorageDirectory)?
        .to_string_lossy();
    let temporary = parent.join(format!(".{file_name}.{}.tmp", uuid::Uuid::new_v4()));

    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|_| CloudSyncProtectionError::SecretStorage)?;
        file.write_all(encoded)
            .map_err(|_| CloudSyncProtectionError::SecretStorage)?;
        file.flush()
            .map_err(|_| CloudSyncProtectionError::SecretStorage)?;
        file.sync_all()
            .map_err(|_| CloudSyncProtectionError::SecretStorage)?;
        drop(file);

        match fs::hard_link(&temporary, path) {
            Ok(()) => {
                #[cfg(target_os = "android")]
                File::open(parent)
                    .and_then(|directory| directory.sync_all())
                    .map_err(|_| CloudSyncProtectionError::SecretStorage)?;
                Ok(())
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
            Err(_) => Err(CloudSyncProtectionError::SecretStorage),
        }
    })();

    let _ = fs::remove_file(&temporary);
    result
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{Arc, Barrier},
        thread,
    };

    use aes_gcm::{
        aead::{Aead, KeyInit},
        Aes256Gcm, Nonce,
    };
    use sha2::{Digest, Sha256};
    use tempfile::tempdir;

    use super::*;

    fn context(purpose: &str) -> CloudSyncProtectionContext {
        CloudSyncProtectionContext::new(
            "fingerprint".to_owned(),
            "container".to_owned(),
            "private".to_owned(),
            "zone".to_owned(),
            "messages".to_owned(),
            2,
            purpose.to_owned(),
        )
        .expect("test context should be valid")
    }

    fn test_encryptor(
        key: [u8; 32],
    ) -> (
        impl Fn(&[u8]) -> Result<Vec<u8>, CloudSyncProtectionError> + Clone,
        impl Fn(&[u8]) -> Result<Vec<u8>, CloudSyncProtectionError> + Clone,
    ) {
        let cipher = Arc::new(Aes256Gcm::new_from_slice(&key).expect("test key"));
        let encrypt_cipher = cipher.clone();
        let encrypt = move |plaintext: &[u8]| {
            let nonce: [u8; 12] = rand::random();
            let mut result = nonce.to_vec();
            result.extend_from_slice(
                &encrypt_cipher
                    .encrypt(Nonce::from_slice(&nonce), plaintext)
                    .map_err(|_| CloudSyncProtectionError::KeyUnavailable)?,
            );
            Ok(result)
        };
        let decrypt = move |ciphertext: &[u8]| {
            if ciphertext.len() < MIN_GCM_CIPHERTEXT_BYTES {
                return Err(CloudSyncProtectionError::InvalidProtectedValue);
            }
            cipher
                .decrypt(Nonce::from_slice(&ciphertext[..12]), &ciphertext[12..])
                .map_err(|_| CloudSyncProtectionError::InvalidProtectedValue)
        };
        (encrypt, decrypt)
    }

    #[test]
    fn authenticated_envelope_rejects_scope_and_purpose_moves() {
        let original = context("checkpointToken");
        let encoded = encode_inner(&original, b"opaque token").expect("encode");
        let (decoded, plaintext) = decode_inner(&encoded).expect("decode");
        assert!(decoded == original);
        assert_eq!(plaintext, b"opaque token");
        assert!(decoded != context("serverRecordId"));

        let different_scope = CloudSyncProtectionContext::new(
            "other-fingerprint".to_owned(),
            "container".to_owned(),
            "private".to_owned(),
            "zone".to_owned(),
            "messages".to_owned(),
            2,
            "checkpointToken".to_owned(),
        )
        .expect("second context");
        assert!(decoded != different_scope);
    }

    #[test]
    fn inner_envelope_rejects_truncation_and_trailing_bytes() {
        let mut encoded = encode_inner(&context("rawRecord"), b"record").expect("encode");
        assert!(decode_inner(&encoded[..encoded.len() - 1]).is_err());
        encoded.push(0);
        assert!(decode_inner(&encoded).is_err());
    }

    #[test]
    fn encrypted_secret_file_is_race_stable_and_corruption_fails_closed() {
        let directory = tempdir().expect("temporary directory");
        let path = directory.path().join(INSTALL_SECRET_FILE_NAME);
        let (encrypt, decrypt) = test_encryptor([7; 32]);

        let first =
            load_or_create_encrypted_install_secret(&path, encrypt.clone(), decrypt.clone())
                .expect("first secret");
        let second =
            load_or_create_encrypted_install_secret(&path, encrypt.clone(), decrypt.clone())
                .expect("same secret");
        assert_eq!(first, second);

        let original = fs::read(&path).expect("read secret file");
        fs::write(&path, &original[..original.len() / 2]).expect("truncate test file");
        assert!(load_or_create_encrypted_install_secret(&path, encrypt, decrypt).is_err());
        assert_eq!(
            fs::read(&path).expect("corrupt file remains"),
            original[..original.len() / 2]
        );
    }

    #[test]
    fn encrypted_secret_file_concurrent_creators_converge() {
        let directory = tempdir().expect("temporary directory");
        let path = Arc::new(directory.path().join(INSTALL_SECRET_FILE_NAME));
        let barrier = Arc::new(Barrier::new(8));
        let mut workers = Vec::new();

        for _ in 0..8 {
            let path = path.clone();
            let barrier = barrier.clone();
            workers.push(thread::spawn(move || {
                let (encrypt, decrypt) = test_encryptor([19; 32]);
                barrier.wait();
                load_or_create_encrypted_install_secret(&path, encrypt, decrypt)
                    .expect("concurrent creator should converge")
            }));
        }

        let secrets: Vec<_> = workers
            .into_iter()
            .map(|worker| worker.join().expect("worker should not panic"))
            .collect();
        assert!(secrets.windows(2).all(|pair| pair[0] == pair[1]));
    }

    #[test]
    fn fingerprint_uses_keyed_hmac_not_plain_sha256() {
        let secret = [11; 32];
        let raw_identifier = b"low-entropy-account-id";
        let mut hmac = <HmacSha256 as Mac>::new_from_slice(&secret).expect("HMAC key");
        hmac.update(FINGERPRINT_DOMAIN);
        hmac.update(raw_identifier);
        let keyed = hmac.finalize().into_bytes();
        let plain = Sha256::digest(raw_identifier);
        assert_ne!(keyed.as_slice(), plain.as_slice());
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_round_trip_rejects_tampering_and_cross_context_move() {
        let directory = tempdir().expect("temporary directory");
        let storage = directory.path().to_string_lossy().into_owned();
        let ciphertext = protect(
            storage.clone(),
            "fingerprint".to_owned(),
            "container".to_owned(),
            "private".to_owned(),
            "zone".to_owned(),
            "messages".to_owned(),
            2,
            "checkpointToken".to_owned(),
            "opaque token".to_owned(),
        )
        .expect("protect");

        assert_eq!(
            unprotect(
                storage.clone(),
                "fingerprint".to_owned(),
                "container".to_owned(),
                "private".to_owned(),
                "zone".to_owned(),
                "messages".to_owned(),
                2,
                "checkpointToken".to_owned(),
                ciphertext.clone(),
            )
            .expect("unprotect"),
            "opaque token"
        );

        assert!(unprotect(
            storage.clone(),
            "fingerprint".to_owned(),
            "container".to_owned(),
            "private".to_owned(),
            "other-zone".to_owned(),
            "messages".to_owned(),
            2,
            "checkpointToken".to_owned(),
            ciphertext.clone(),
        )
        .is_err());

        assert!(unprotect(
            storage.clone(),
            "fingerprint".to_owned(),
            "container".to_owned(),
            "private".to_owned(),
            "zone".to_owned(),
            "messages".to_owned(),
            2,
            "serverRecordId".to_owned(),
            ciphertext.clone(),
        )
        .is_err());

        let mut tampered = ciphertext.into_bytes();
        let last = tampered.len() - 1;
        tampered[last] = if tampered[last] == b'A' { b'B' } else { b'A' };
        assert!(unprotect(
            storage,
            "fingerprint".to_owned(),
            "container".to_owned(),
            "private".to_owned(),
            "zone".to_owned(),
            "messages".to_owned(),
            2,
            "checkpointToken".to_owned(),
            String::from_utf8(tampered).expect("ASCII ciphertext"),
        )
        .is_err());
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_fingerprint_is_stable_keyed_and_install_scoped() {
        let directory = tempdir().expect("temporary directory");
        let storage = directory.path().to_string_lossy().into_owned();
        let raw = "low-entropy-account-id".to_owned();
        let first = fingerprint_account(storage.clone(), raw.clone()).expect("first fingerprint");
        let second = fingerprint_account(storage.clone(), raw.clone()).expect("stable fingerprint");
        let plain = URL_SAFE_NO_PAD.encode(Sha256::digest(raw.as_bytes()));

        assert_eq!(first, second);
        assert_ne!(first, plain);
        assert_eq!(first.len(), 43);
        assert!(directory.path().join(INSTALL_SECRET_FILE_NAME).is_file());

        let other_directory = tempdir().expect("second temporary directory");
        let other = fingerprint_account(other_directory.path().to_string_lossy().into_owned(), raw)
            .expect("second installation fingerprint");
        assert_ne!(first, other);
    }
}
